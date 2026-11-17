// SPDX-License-Identifier: 0BSD
// Licensed under the 0BSD license; see the LICENSE file.

/// Chain Payments on Sui: exact, quoted payments to a merchant, with an optional prepaid-period ledger.
///
/// ## Model
///
/// A **`Merchant`** (a shared object, created by anyone) names who receives payments, the ed25519 public key that signs
/// its **quotes**, the coin types it accepts (each with a minimum amount per unit) and its limits. A merchant's
/// off-chain service (the Chain Payments service) issues a quote for a checkout session: an exact amount of one coin
/// type, valid for a short time, for a number of units (for example months of a plan), optionally extending a
/// subscription reference by `units × period_ms`.
///
/// `pay<T>` verifies the quote's signature, takes **exactly** the quoted amount from the payer's coin for the
/// recipient, returns the change to the payer **in the same transaction**, extends the ledger and emits `Paid`. The
/// payer sees one exact price; there is no escrow and no refund step. Anyone may pay for any subscription reference
/// (a gift), and the reference is opaque (the merchant's own random identifier, never personal data).
///
/// ## What a leaked quote key can do
///
/// Sign quotes. Every quote must still be at or above the merchant's on-chain minimum per unit for its coin type, so a
/// leaked key can at worst sell at those minimums until the key is rotated (`set_quote_key`) or the merchant paused.
///
/// ## Governance
///
/// The `MerchantCap` sets the key, the accepted coins and minimums, the limits and the pause; a new recipient takes
/// effect only after `RECIPIENT_DELAY_MS` (proposed, then confirmed), so a stolen cap cannot redirect payments silently.
module chain_payments::chain_payments;

use std::ascii::String as AsciiString;
use std::type_name::{Self, TypeName};
use sui::bcs;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::ed25519;
use sui::event;
use sui::table::{Self, Table};
use sui::vec_map::{Self, VecMap};

// ── Constants ────────────────────────────────────────────────────────────────

/// The package version this code implements (bumped with a `migrate` at a behaviour-changing upgrade).
const VERSION: u64 = 1;
/// Domain separation for quote signatures.
const QUOTE_DOMAIN: vector<u8> = b"chain-payments:quote:v1";
/// A quote may be valid for at most this long from the time it is used (the service issues 120 s quotes).
const MAX_QUOTE_TTL_MS: u64 = 10 * 60 * 1000;
/// A proposed recipient takes effect after two days.
const RECIPIENT_DELAY_MS: u64 = 2 * 24 * 60 * 60 * 1000;
/// The longest any ledger may run ahead of now: 120 average months (365.25 / 12 days each).
const HARD_MAX_AHEAD_MS: u64 = 120 * 2_629_800_000;
/// The most units one payment may buy.
const HARD_MAX_UNITS: u64 = 120;
/// Bounds on opaque identifiers.
const MAX_ID_BYTES: u64 = 64;
/// The platform fee on every payment, in basis points of the quoted amount: 0.2 %, out of the merchant's share (the
/// payer always pays exactly the quote). The holder of `PlatformAdminCap` may change it, never above `MAX_FEE_BPS`.
const DEFAULT_FEE_BPS: u64 = 20;
/// The hard ceiling of the platform fee (1 %): a promise to every merchant of this package, which nobody can upgrade.
const MAX_FEE_BPS: u64 = 100;

// ── Errors ───────────────────────────────────────────────────────────────────

const EWrongVersion: u64 = 0;
const EPaused: u64 = 1;
const EQuoteExpired: u64 = 2;
const EQuoteTooLong: u64 = 3;
const ENonceUsed: u64 = 4;
const ECoinNotAccepted: u64 = 5;
const EBelowMinimum: u64 = 6;
const ETooManyUnits: u64 = 7;
const EBadSignature: u64 = 8;
const EInsufficientPayment: u64 = 9;
const ETooFarAhead: u64 = 10;
const EWrongCap: u64 = 11;
const EBadKey: u64 = 12;
const EBadIdentifier: u64 = 13;
const ENoPendingRecipient: u64 = 14;
const ERecipientNotYetDue: u64 = 15;
const EBadLimits: u64 = 16;
const ENotExpired: u64 = 17;
const EZeroUnits: u64 = 18;
const EBadRecipient: u64 = 19;
const EZeroMinimum: u64 = 20;
const EFeeTooHigh: u64 = 21;

// ── Objects ──────────────────────────────────────────────────────────────────

public struct PendingRecipient has copy, drop, store {
    recipient: address,
    effective_ms: u64,
}

public struct Merchant has key {
    id: UID,
    version: u64,
    recipient: address,
    pending_recipient: Option<PendingRecipient>,
    /// ed25519 public key (32 bytes) that signs this merchant's quotes.
    quote_key: vector<u8>,
    paused: bool,
    /// Accepted coin types → minimum amount per unit (in the coin's smallest unit).
    accepted: VecMap<TypeName, u64>,
    max_units: u64,
    max_ahead_ms: u64,
    /// Used quote nonces → the quote's expiry (pruned by anyone once expired).
    nonces: Table<vector<u8>, u64>,
    /// Subscription references → paid until (ms since the epoch).
    ledger: Table<vector<u8>, u64>,
}

/// Created once when the package is published, then shared: where the platform fee goes and how much it is.
public struct PlatformConfig has key {
    id: UID,
    treasury: address,
    fee_bps: u64,
}

/// Authorises changes to `PlatformConfig` (minted to the publisher; on mainnet, held by the entity's multisig).
public struct PlatformAdminCap has key, store {
    id: UID,
}

public struct MerchantCap has key, store {
    id: UID,
    merchant_id: ID,
}

// ── Events ───────────────────────────────────────────────────────────────────

public struct MerchantCreated has copy, drop {
    merchant_id: ID,
    recipient: address,
}

public struct Paid has copy, drop {
    merchant_id: ID,
    session: vector<u8>,
    payer: address,
    coin_type: AsciiString,
    amount: u64,
    units: u64,
    subscription_ref: vector<u8>,
    /// 0 when the payment extends no ledger.
    paid_until_ms: u64,
    nonce: vector<u8>,
    /// Of `amount`, what went to the platform treasury; the merchant's recipient received the rest.
    platform_fee: u64,
}

// Every governance change has its own event carrying the old and new values, so a watcher can alert on (and stop
// quoting for) an unexpected change from the event alone. The recipient change is the one with a delay: its proposal
// is public for RECIPIENT_DELAY_MS before it can take effect, which is only useful while someone watches.

public struct RecipientProposed has copy, drop {
    merchant_id: ID,
    current: address,
    proposed: address,
    effective_ms: u64,
}

public struct RecipientProposalCancelled has copy, drop {
    merchant_id: ID,
    proposed: address,
}

public struct RecipientChanged has copy, drop {
    merchant_id: ID,
    old: address,
    new: address,
}

public struct QuoteKeyChanged has copy, drop {
    merchant_id: ID,
    old_key: vector<u8>,
    new_key: vector<u8>,
}

/// `min_per_unit` is none when the coin type is no longer accepted.
public struct AcceptedChanged has copy, drop {
    merchant_id: ID,
    coin_type: AsciiString,
    min_per_unit: Option<u64>,
}

public struct PausedChanged has copy, drop {
    merchant_id: ID,
    paused: bool,
}

public struct PlatformConfigChanged has copy, drop {
    config_id: ID,
    old_treasury: address,
    treasury: address,
    old_fee_bps: u64,
    fee_bps: u64,
}

public struct LimitsChanged has copy, drop {
    merchant_id: ID,
    max_units: u64,
    max_ahead_ms: u64,
}

// ── Creation ─────────────────────────────────────────────────────────────────

fun init(ctx: &mut TxContext) {
    transfer::share_object(PlatformConfig { id: object::new(ctx), treasury: ctx.sender(), fee_bps: DEFAULT_FEE_BPS });
    transfer::public_transfer(PlatformAdminCap { id: object::new(ctx) }, ctx.sender());
}

/// The platform fee for `amount` (rounded down).
public fun platform_fee(config: &PlatformConfig, amount: u64): u64 {
    (((amount as u128) * (config.fee_bps as u128) / 10_000) as u64)
}

public fun platform_treasury(config: &PlatformConfig): address { config.treasury }

public fun platform_fee_bps(config: &PlatformConfig): u64 { config.fee_bps }

public fun max_fee_bps(): u64 { MAX_FEE_BPS }

public fun set_platform_fee_bps(_: &PlatformAdminCap, config: &mut PlatformConfig, fee_bps: u64) {
    assert!(fee_bps <= MAX_FEE_BPS, EFeeTooHigh);
    let old_fee_bps = config.fee_bps;
    config.fee_bps = fee_bps;
    config_changed(config, config.treasury, old_fee_bps);
}

/// The treasury is never the zero address (fees sent there would be lost).
public fun set_platform_treasury(_: &PlatformAdminCap, config: &mut PlatformConfig, treasury: address) {
    assert!(treasury != @0x0, EBadRecipient);
    let old_treasury = config.treasury;
    config.treasury = treasury;
    config_changed(config, old_treasury, config.fee_bps);
}

fun config_changed(config: &PlatformConfig, old_treasury: address, old_fee_bps: u64) {
    event::emit(PlatformConfigChanged {
        config_id: object::id(config),
        old_treasury,
        treasury: config.treasury,
        old_fee_bps,
        fee_bps: config.fee_bps,
    });
}

/// Creates (and shares) a merchant; returns its capability to the caller. Permissionless.
public fun create_merchant(
    recipient: address,
    quote_key: vector<u8>,
    max_units: u64,
    max_ahead_ms: u64,
    ctx: &mut TxContext,
): MerchantCap {
    assert!(quote_key.length() == 32, EBadKey);
    assert!(recipient != @0x0, EBadRecipient);
    check_limits(max_units, max_ahead_ms);
    let merchant = Merchant {
        id: object::new(ctx),
        version: VERSION,
        recipient,
        pending_recipient: option::none(),
        quote_key,
        paused: false,
        accepted: vec_map::empty(),
        max_units,
        max_ahead_ms,
        nonces: table::new(ctx),
        ledger: table::new(ctx),
    };
    let merchant_id = object::id(&merchant);
    event::emit(MerchantCreated { merchant_id, recipient });
    transfer::share_object(merchant);
    MerchantCap { id: object::new(ctx), merchant_id }
}

// ── Paying ───────────────────────────────────────────────────────────────────

/// The exact bytes a quote signature covers: the domain tag, then each field in BCS.
public fun quote_message(
    merchant_id: ID,
    session: vector<u8>,
    coin_type: AsciiString,
    amount: u64,
    units: u64,
    period_ms: u64,
    subscription_ref: vector<u8>,
    expires_ms: u64,
    nonce: vector<u8>,
): vector<u8> {
    let mut msg = QUOTE_DOMAIN;
    msg.append(bcs::to_bytes(&merchant_id));
    msg.append(bcs::to_bytes(&session));
    msg.append(bcs::to_bytes(&coin_type));
    msg.append(bcs::to_bytes(&amount));
    msg.append(bcs::to_bytes(&units));
    msg.append(bcs::to_bytes(&period_ms));
    msg.append(bcs::to_bytes(&subscription_ref));
    msg.append(bcs::to_bytes(&expires_ms));
    msg.append(bcs::to_bytes(&nonce));
    msg
}

/// Pays a signed quote with a coin of type `T`: exactly `amount` goes to the merchant's recipient, the rest of `payment`
/// goes back to the sender in this transaction. With a non-empty `subscription_ref` and a `period_ms`, the ledger entry
/// is extended by `units × period_ms` from the later of now and its current end.
#[allow(lint(self_transfer))]
public fun pay<T>(
    config: &PlatformConfig,
    merchant: &mut Merchant,
    session: vector<u8>,
    amount: u64,
    units: u64,
    period_ms: u64,
    subscription_ref: vector<u8>,
    expires_ms: u64,
    nonce: vector<u8>,
    signature: vector<u8>,
    mut payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(merchant.version == VERSION, EWrongVersion);
    assert!(!merchant.paused, EPaused);
    let now = clock.timestamp_ms();
    assert!(now < expires_ms, EQuoteExpired);
    assert!(expires_ms - now <= MAX_QUOTE_TTL_MS, EQuoteTooLong);
    assert!(units > 0, EZeroUnits);
    assert!(units <= merchant.max_units, ETooManyUnits);
    assert!(
        session.length() > 0 && session.length() <= MAX_ID_BYTES && nonce.length() > 0 && nonce.length() <= MAX_ID_BYTES
            && subscription_ref.length() <= MAX_ID_BYTES,
        EBadIdentifier,
    );
    assert!(!merchant.nonces.contains(nonce), ENonceUsed);

    let coin_type = type_name::with_defining_ids<T>();
    assert!(merchant.accepted.contains(&coin_type), ECoinNotAccepted);
    let min_per_unit = *merchant.accepted.get(&coin_type);
    assert!((amount as u128) >= (min_per_unit as u128) * (units as u128), EBelowMinimum);

    let merchant_id = object::id(merchant);
    let coin_name = coin_type.into_string();
    let msg = quote_message(
        merchant_id,
        session,
        coin_name,
        amount,
        units,
        period_ms,
        subscription_ref,
        expires_ms,
        nonce,
    );
    assert!(ed25519::ed25519_verify(&signature, &merchant.quote_key, &msg), EBadSignature);

    // Exact take (the platform fee out of it, the rest to the merchant), change back in the same transaction.
    assert!(payment.value() >= amount, EInsufficientPayment);
    let mut take = payment.split(amount, ctx);
    let fee = platform_fee(config, amount);
    if (fee > 0) {
        transfer::public_transfer(take.split(fee, ctx), config.treasury);
    };
    transfer::public_transfer(take, merchant.recipient);
    if (payment.value() > 0) {
        transfer::public_transfer(payment, ctx.sender());
    } else {
        coin::destroy_zero(payment);
    };

    merchant.nonces.add(nonce, expires_ms);

    let mut paid_until_ms = 0;
    if (subscription_ref.length() > 0 && period_ms > 0) {
        let extension = (units as u128) * (period_ms as u128);
        let current = if (merchant.ledger.contains(subscription_ref)) {
            *merchant.ledger.borrow(subscription_ref)
        } else { 0 };
        let start = if (current > now) { current } else { now };
        let end = (start as u128) + extension;
        assert!(end - (now as u128) <= (merchant.max_ahead_ms as u128), ETooFarAhead);
        paid_until_ms = (end as u64);
        if (merchant.ledger.contains(subscription_ref)) {
            *merchant.ledger.borrow_mut(subscription_ref) = paid_until_ms;
        } else {
            merchant.ledger.add(subscription_ref, paid_until_ms);
        };
    };

    event::emit(Paid {
        merchant_id,
        session,
        payer: ctx.sender(),
        coin_type: coin_name,
        amount,
        units,
        subscription_ref,
        paid_until_ms,
        nonce,
        platform_fee: fee,
    });
}

/// Removes used nonces whose quotes have expired (their storage rebate goes to the caller). Permissionless.
public fun prune_nonces(merchant: &mut Merchant, nonces: vector<vector<u8>>, clock: &Clock) {
    let now = clock.timestamp_ms();
    let mut i = 0;
    while (i < nonces.length()) {
        let n = nonces[i];
        if (merchant.nonces.contains(n)) {
            let expires = *merchant.nonces.borrow(n);
            assert!(expires <= now, ENotExpired);
            merchant.nonces.remove(n);
        };
        i = i + 1;
    };
}

// ── Reads ────────────────────────────────────────────────────────────────────

public fun paid_until(merchant: &Merchant, subscription_ref: vector<u8>): u64 {
    if (merchant.ledger.contains(subscription_ref)) { *merchant.ledger.borrow(subscription_ref) } else { 0 }
}

public fun recipient(merchant: &Merchant): address { merchant.recipient }

public fun quote_key(merchant: &Merchant): vector<u8> { merchant.quote_key }

public fun is_paused(merchant: &Merchant): bool { merchant.paused }

public fun minimum_per_unit<T>(merchant: &Merchant): Option<u64> {
    let t = type_name::with_defining_ids<T>();
    if (merchant.accepted.contains(&t)) { option::some(*merchant.accepted.get(&t)) } else { option::none() }
}

public fun nonce_used(merchant: &Merchant, nonce: vector<u8>): bool { merchant.nonces.contains(nonce) }

public fun package_version(): u64 { VERSION }

public fun recipient_delay_ms(): u64 { RECIPIENT_DELAY_MS }

// ── Governance (MerchantCap) ─────────────────────────────────────────────────

fun check_cap(cap: &MerchantCap, merchant: &Merchant) {
    assert!(cap.merchant_id == object::id(merchant), EWrongCap);
    assert!(merchant.version == VERSION, EWrongVersion);
}

fun check_limits(max_units: u64, max_ahead_ms: u64) {
    assert!(max_units > 0 && max_units <= HARD_MAX_UNITS, EBadLimits);
    assert!(max_ahead_ms > 0 && max_ahead_ms <= HARD_MAX_AHEAD_MS, EBadLimits);
}

/// Accepts coin type `T` (or changes its minimum per unit). The minimum is at least 1 of the coin's smallest unit: a
/// zero minimum would let a quote key sign a payment of nothing.
public fun set_accepted<T>(cap: &MerchantCap, merchant: &mut Merchant, min_per_unit: u64) {
    check_cap(cap, merchant);
    assert!(min_per_unit > 0, EZeroMinimum);
    let t = type_name::with_defining_ids<T>();
    if (merchant.accepted.contains(&t)) {
        *merchant.accepted.get_mut(&t) = min_per_unit;
    } else {
        merchant.accepted.insert(t, min_per_unit);
    };
    event::emit(AcceptedChanged {
        merchant_id: object::id(merchant),
        coin_type: t.into_string(),
        min_per_unit: option::some(min_per_unit),
    });
}

public fun remove_accepted<T>(cap: &MerchantCap, merchant: &mut Merchant) {
    check_cap(cap, merchant);
    let t = type_name::with_defining_ids<T>();
    if (merchant.accepted.contains(&t)) {
        merchant.accepted.remove(&t);
    };
    event::emit(AcceptedChanged { merchant_id: object::id(merchant), coin_type: t.into_string(), min_per_unit: option::none() });
}

public fun set_quote_key(cap: &MerchantCap, merchant: &mut Merchant, quote_key: vector<u8>) {
    check_cap(cap, merchant);
    assert!(quote_key.length() == 32, EBadKey);
    let old_key = merchant.quote_key;
    merchant.quote_key = quote_key;
    event::emit(QuoteKeyChanged { merchant_id: object::id(merchant), old_key, new_key: quote_key });
}

public fun set_paused(cap: &MerchantCap, merchant: &mut Merchant, paused: bool) {
    check_cap(cap, merchant);
    merchant.paused = paused;
    event::emit(PausedChanged { merchant_id: object::id(merchant), paused });
}

public fun set_limits(cap: &MerchantCap, merchant: &mut Merchant, max_units: u64, max_ahead_ms: u64) {
    check_cap(cap, merchant);
    check_limits(max_units, max_ahead_ms);
    merchant.max_units = max_units;
    merchant.max_ahead_ms = max_ahead_ms;
    event::emit(LimitsChanged { merchant_id: object::id(merchant), max_units, max_ahead_ms });
}

/// Proposes a new recipient; it takes effect after `RECIPIENT_DELAY_MS` with `confirm_recipient`. The zero address
/// (where coins are lost) is refused, as at creation.
public fun propose_recipient(cap: &MerchantCap, merchant: &mut Merchant, recipient: address, clock: &Clock) {
    check_cap(cap, merchant);
    assert!(recipient != @0x0, EBadRecipient);
    let effective_ms = clock.timestamp_ms() + RECIPIENT_DELAY_MS;
    merchant.pending_recipient = option::some(PendingRecipient { recipient, effective_ms });
    event::emit(RecipientProposed {
        merchant_id: object::id(merchant),
        current: merchant.recipient,
        proposed: recipient,
        effective_ms,
    });
}

public fun cancel_recipient(cap: &MerchantCap, merchant: &mut Merchant) {
    check_cap(cap, merchant);
    if (merchant.pending_recipient.is_some()) {
        let p = merchant.pending_recipient.extract();
        event::emit(RecipientProposalCancelled { merchant_id: object::id(merchant), proposed: p.recipient });
    };
}

public fun confirm_recipient(cap: &MerchantCap, merchant: &mut Merchant, clock: &Clock) {
    check_cap(cap, merchant);
    assert!(merchant.pending_recipient.is_some(), ENoPendingRecipient);
    let p = merchant.pending_recipient.extract();
    assert!(clock.timestamp_ms() >= p.effective_ms, ERecipientNotYetDue);
    let old = merchant.recipient;
    merchant.recipient = p.recipient;
    event::emit(RecipientChanged { merchant_id: object::id(merchant), old, new: p.recipient });
}

public fun pending_recipient(merchant: &Merchant): Option<PendingRecipient> { merchant.pending_recipient }

// ── Test-only helpers ────────────────────────────────────────────────────────

#[test_only]
public fun merchant_id_of(cap: &MerchantCap): ID { cap.merchant_id }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
public fun recipient_proposed_for_testing(merchant_id: ID, current: address, proposed: address, effective_ms: u64): RecipientProposed {
    RecipientProposed { merchant_id, current, proposed, effective_ms }
}

#[test_only]
public fun recipient_changed_for_testing(merchant_id: ID, old: address, new: address): RecipientChanged {
    RecipientChanged { merchant_id, old, new }
}

#[test_only]
public fun quote_key_changed_for_testing(merchant_id: ID, old_key: vector<u8>, new_key: vector<u8>): QuoteKeyChanged {
    QuoteKeyChanged { merchant_id, old_key, new_key }
}

#[test_only]
public fun accepted_changed_for_testing<T>(merchant_id: ID, min_per_unit: Option<u64>): AcceptedChanged {
    AcceptedChanged { merchant_id, coin_type: type_name::with_defining_ids<T>().into_string(), min_per_unit }
}

#[test_only]
public fun set_version_for_testing(merchant: &mut Merchant, version: u64) { merchant.version = version; }

#[test_only]
public fun destroy_cap_for_testing(cap: MerchantCap) {
    let MerchantCap { id, merchant_id: _ } = cap;
    id.delete();
}
