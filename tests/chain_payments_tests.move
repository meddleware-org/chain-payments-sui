#[test_only]
module chain_payments::chain_payments_tests;

use chain_payments::chain_payments::{Self, Merchant, MerchantCap};
use chain_payments::vectors;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

const OWNER: address = @0xA;
const RECIPIENT: address = @0xB;
const PAYER: address = @0xC;
const FRIEND: address = @0xD;
const MONTH_MS: u64 = 2_629_800_000;

public struct OTHER has drop {}

/// Creates the merchant (the first object of 0xA: the id the vectors were signed for), accepts SUI at 1000 per unit.
fun setup(): (Scenario, Clock) {
    let mut s = ts::begin(OWNER);
    let cap = chain_payments::create_merchant(RECIPIENT, vectors::public_key(), 12, 24 * MONTH_MS, s.ctx());
    transfer::public_transfer(cap, OWNER);
    s.next_tx(OWNER);
    {
        let cap = s.take_from_sender<MerchantCap>();
        let mut m = s.take_shared<Merchant>();
        chain_payments::set_accepted<SUI>(&cap, &mut m, 1000);
        ts::return_shared(m);
        s.return_to_sender(cap);
    };
    let mut clock = clock::create_for_testing(s.ctx());
    clock.set_for_testing(1000);
    (s, clock)
}

fun coin(s: &mut Scenario, value: u64): Coin<SUI> {
    coin::mint_for_testing<SUI>(value, s.ctx())
}

fun pay_basic(s: &mut Scenario, clock: &Clock, value: u64) {
    let c = coin(s, value);
    let mut m = s.take_shared<Merchant>();
    chain_payments::pay<SUI>(&mut m, b"s1", 5000, 2, MONTH_MS, b"acct1", 61_000, b"n1", vectors::basic_signature(), c, clock, s.ctx());
    ts::return_shared(m);
}

#[test]
fun message_matches_the_vectors() {
    let (s, clock) = setup();
    let msg = chain_payments::quote_message(
        object::id_from_address(@0x034401905bebdf8c04f3cd5f04f442a39372c8dc321c29edfb4f9cb30b23ab96),
        b"s1",
        std::type_name::with_defining_ids<SUI>().into_string(),
        5000, 2, MONTH_MS, b"acct1", 61_000, b"n1",
    );
    assert!(msg == vectors::basic_message());
    clock.destroy_for_testing();
    s.end();
}

#[test]
fun pays_exactly_and_returns_the_change() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    pay_basic(&mut s, &clock, 7000);
    s.next_tx(PAYER);
    {
        let to_recipient = s.take_from_address<Coin<SUI>>(RECIPIENT);
        assert!(to_recipient.value() == 5000);
        ts::return_to_address(RECIPIENT, to_recipient);
        let change = s.take_from_sender<Coin<SUI>>();
        assert!(change.value() == 2000);
        s.return_to_sender(change);
        let m = s.take_shared<Merchant>();
        assert!(chain_payments::paid_until(&m, b"acct1") == 1000 + 2 * MONTH_MS);
        assert!(chain_payments::nonce_used(&m, b"n1"));
        ts::return_shared(m);
    };
    clock.destroy_for_testing();
    s.end();
}

#[test]
fun exact_payment_leaves_no_change_coin() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    pay_basic(&mut s, &clock, 5000);
    s.next_tx(PAYER);
    assert!(!ts::has_most_recent_for_sender<Coin<SUI>>(&s));
    clock.destroy_for_testing();
    s.end();
}

#[test]
fun anyone_may_pay_for_a_reference_and_periods_add_up() {
    let (mut s, mut clock) = setup();
    s.next_tx(PAYER);
    pay_basic(&mut s, &clock, 5000);
    // A friend extends the same reference by one more month, a little later.
    clock.set_for_testing(2000);
    s.next_tx(FRIEND);
    {
        let c = coin(&mut s, 2500);
        let mut m = s.take_shared<Merchant>();
        chain_payments::pay<SUI>(&mut m, b"s2", 2500, 1, MONTH_MS, b"acct1", 61_000, b"n2", vectors::second_signature(), c, &clock, s.ctx());
        assert!(chain_payments::paid_until(&m, b"acct1") == 1000 + 3 * MONTH_MS);
        ts::return_shared(m);
    };
    clock.destroy_for_testing();
    s.end();
}

#[test]
fun a_one_off_payment_extends_no_ledger() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    {
        let c = coin(&mut s, 5000);
        let mut m = s.take_shared<Merchant>();
        chain_payments::pay<SUI>(&mut m, b"s4", 5000, 1, 0, b"", 61_000, b"n4", vectors::one_off_signature(), c, &clock, s.ctx());
        assert!(chain_payments::paid_until(&m, b"") == 0);
        ts::return_shared(m);
    };
    clock.destroy_for_testing();
    s.end();
}

#[test, expected_failure(abort_code = chain_payments::ENonceUsed)]
fun a_quote_cannot_be_used_twice() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    pay_basic(&mut s, &clock, 5000);
    s.next_tx(PAYER);
    pay_basic(&mut s, &clock, 5000);
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EQuoteExpired)]
fun an_expired_quote_is_refused() {
    let (mut s, mut clock) = setup();
    clock.set_for_testing(61_000);
    s.next_tx(PAYER);
    pay_basic(&mut s, &clock, 5000);
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EQuoteTooLong)]
fun a_quote_valid_for_too_long_is_refused() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    {
        let c = coin(&mut s, 5000);
        let mut m = s.take_shared<Merchant>();
        chain_payments::pay<SUI>(&mut m, b"s1", 5000, 2, MONTH_MS, b"acct1", 1000 + 60 * 60 * 1000, b"n1", vectors::basic_signature(), c, &clock, s.ctx());
        ts::return_shared(m);
    };
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadSignature)]
fun a_changed_amount_breaks_the_signature() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    {
        let c = coin(&mut s, 5000);
        let mut m = s.take_shared<Merchant>();
        chain_payments::pay<SUI>(&mut m, b"s1", 4000, 2, MONTH_MS, b"acct1", 61_000, b"n1", vectors::basic_signature(), c, &clock, s.ctx());
        ts::return_shared(m);
    };
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadSignature)]
fun a_changed_reference_breaks_the_signature() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    {
        let c = coin(&mut s, 5000);
        let mut m = s.take_shared<Merchant>();
        chain_payments::pay<SUI>(&mut m, b"s1", 5000, 2, MONTH_MS, b"someone-else", 61_000, b"n1", vectors::basic_signature(), c, &clock, s.ctx());
        ts::return_shared(m);
    };
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::ECoinNotAccepted)]
fun a_coin_type_not_accepted_is_refused() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    {
        let c = coin::mint_for_testing<OTHER>(5000, s.ctx());
        let mut m = s.take_shared<Merchant>();
        chain_payments::pay<OTHER>(&mut m, b"s1", 5000, 2, MONTH_MS, b"acct1", 61_000, b"n1", vectors::basic_signature(), c, &clock, s.ctx());
        ts::return_shared(m);
    };
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBelowMinimum)]
fun a_quote_below_the_minimum_is_refused_even_if_signed() {
    let (mut s, clock) = setup();
    s.next_tx(OWNER);
    {
        let cap = s.take_from_sender<MerchantCap>();
        let mut m = s.take_shared<Merchant>();
        chain_payments::set_accepted<SUI>(&cap, &mut m, 3000);
        ts::return_shared(m);
        s.return_to_sender(cap);
    };
    s.next_tx(PAYER);
    pay_basic(&mut s, &clock, 5000);
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EInsufficientPayment)]
fun too_small_a_coin_is_refused() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    pay_basic(&mut s, &clock, 4999);
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::ETooFarAhead)]
fun the_ledger_cannot_run_too_far_ahead() {
    let (mut s, clock) = setup();
    s.next_tx(OWNER);
    {
        let cap = s.take_from_sender<MerchantCap>();
        let mut m = s.take_shared<Merchant>();
        chain_payments::set_limits(&cap, &mut m, 12, 6 * MONTH_MS);
        ts::return_shared(m);
        s.return_to_sender(cap);
    };
    s.next_tx(PAYER);
    {
        let c = coin(&mut s, 30_000);
        let mut m = s.take_shared<Merchant>();
        chain_payments::pay<SUI>(&mut m, b"s3", 30_000, 12, MONTH_MS, b"acct1", 61_000, b"n3", vectors::too_far_signature(), c, &clock, s.ctx());
        ts::return_shared(m);
    };
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EPaused)]
fun a_paused_merchant_takes_nothing() {
    let (mut s, clock) = setup();
    s.next_tx(OWNER);
    {
        let cap = s.take_from_sender<MerchantCap>();
        let mut m = s.take_shared<Merchant>();
        chain_payments::set_paused(&cap, &mut m, true);
        ts::return_shared(m);
        s.return_to_sender(cap);
    };
    s.next_tx(PAYER);
    pay_basic(&mut s, &clock, 5000);
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadLimits)]
fun limits_have_a_hard_ceiling() {
    let mut s = ts::begin(OWNER);
    let cap = chain_payments::create_merchant(RECIPIENT, vectors::public_key(), 121, MONTH_MS, s.ctx());
    chain_payments::destroy_cap_for_testing(cap);
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadKey)]
fun a_key_must_be_32_bytes() {
    let mut s = ts::begin(OWNER);
    let cap = chain_payments::create_merchant(RECIPIENT, x"00", 12, MONTH_MS, s.ctx());
    chain_payments::destroy_cap_for_testing(cap);
    abort 99
}

#[test]
fun a_new_recipient_waits_for_the_delay() {
    let (mut s, mut clock) = setup();
    s.next_tx(OWNER);
    {
        let cap = s.take_from_sender<MerchantCap>();
        let mut m = s.take_shared<Merchant>();
        chain_payments::propose_recipient(&cap, &mut m, FRIEND, &clock);
        assert!(chain_payments::recipient(&m) == RECIPIENT);
        clock.set_for_testing(1000 + 2 * 24 * 60 * 60 * 1000);
        chain_payments::confirm_recipient(&cap, &mut m, &clock);
        assert!(chain_payments::recipient(&m) == FRIEND);
        ts::return_shared(m);
        s.return_to_sender(cap);
    };
    clock.destroy_for_testing();
    s.end();
}

#[test, expected_failure(abort_code = chain_payments::ERecipientNotYetDue)]
fun a_new_recipient_cannot_be_confirmed_early() {
    let (mut s, clock) = setup();
    s.next_tx(OWNER);
    {
        let cap = s.take_from_sender<MerchantCap>();
        let mut m = s.take_shared<Merchant>();
        chain_payments::propose_recipient(&cap, &mut m, FRIEND, &clock);
        chain_payments::confirm_recipient(&cap, &mut m, &clock);
        ts::return_shared(m);
        s.return_to_sender(cap);
    };
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EWrongCap)]
fun another_merchants_cap_has_no_power() {
    let (mut s, clock) = setup();
    s.next_tx(FRIEND);
    let other = chain_payments::create_merchant(FRIEND, vectors::public_key(), 12, MONTH_MS, s.ctx());
    s.next_tx(FRIEND);
    {
        let mut m = s.take_shared_by_id<Merchant>(object::id_from_address(@0x034401905bebdf8c04f3cd5f04f442a39372c8dc321c29edfb4f9cb30b23ab96));
        chain_payments::set_paused(&other, &mut m, true);
        ts::return_shared(m);
    };
    chain_payments::destroy_cap_for_testing(other);
    clock.destroy_for_testing();
    abort 99
}

#[test]
fun expired_nonces_can_be_pruned_by_anyone() {
    let (mut s, mut clock) = setup();
    s.next_tx(PAYER);
    pay_basic(&mut s, &clock, 5000);
    clock.set_for_testing(61_000);
    s.next_tx(FRIEND);
    {
        let mut m = s.take_shared<Merchant>();
        chain_payments::prune_nonces(&mut m, vector[b"n1", b"never-used"], &clock);
        assert!(!chain_payments::nonce_used(&m, b"n1"));
        ts::return_shared(m);
    };
    clock.destroy_for_testing();
    s.end();
}

#[test, expected_failure(abort_code = chain_payments::ENotExpired)]
fun live_nonces_cannot_be_pruned() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    pay_basic(&mut s, &clock, 5000);
    s.next_tx(FRIEND);
    {
        let mut m = s.take_shared<Merchant>();
        chain_payments::prune_nonces(&mut m, vector[b"n1"], &clock);
        ts::return_shared(m);
    };
    abort 99
}

#[test]
fun reads_and_governance_round_trip() {
    let (mut s, clock) = setup();
    s.next_tx(OWNER);
    {
        let cap = s.take_from_sender<MerchantCap>();
        let mut m = s.take_shared<Merchant>();
        assert!(chain_payments::recipient(&m) == RECIPIENT);
        assert!(chain_payments::quote_key(&m) == vectors::public_key());
        assert!(!chain_payments::is_paused(&m));
        assert!(chain_payments::minimum_per_unit<SUI>(&m) == option::some(1000));
        assert!(chain_payments::minimum_per_unit<OTHER>(&m).is_none());
        assert!(chain_payments::package_version() == 1);
        assert!(chain_payments::pending_recipient(&m).is_none());
        chain_payments::propose_recipient(&cap, &mut m, FRIEND, &clock);
        assert!(chain_payments::pending_recipient(&m).is_some());
        chain_payments::cancel_recipient(&cap, &mut m);
        assert!(chain_payments::pending_recipient(&m).is_none());
        chain_payments::remove_accepted<SUI>(&cap, &mut m);
        chain_payments::remove_accepted<OTHER>(&cap, &mut m);
        assert!(chain_payments::minimum_per_unit<SUI>(&m).is_none());
        let new_key = x"1111111111111111111111111111111111111111111111111111111111111111";
        chain_payments::set_quote_key(&cap, &mut m, new_key);
        assert!(chain_payments::quote_key(&m) == new_key);
        chain_payments::set_paused(&cap, &mut m, true);
        assert!(chain_payments::is_paused(&m));
        ts::return_shared(m);
        s.return_to_sender(cap);
    };
    clock.destroy_for_testing();
    s.end();
}

#[test, expected_failure(abort_code = chain_payments::EBadKey)]
fun a_rotated_key_must_be_32_bytes() {
    let (mut s, _clock) = setup();
    s.next_tx(OWNER);
    let cap = s.take_from_sender<MerchantCap>();
    let mut m = s.take_shared<Merchant>();
    chain_payments::set_quote_key(&cap, &mut m, x"0102");
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::ENoPendingRecipient)]
fun confirming_without_a_proposal_fails() {
    let (mut s, clock) = setup();
    s.next_tx(OWNER);
    let cap = s.take_from_sender<MerchantCap>();
    let mut m = s.take_shared<Merchant>();
    chain_payments::confirm_recipient(&cap, &mut m, &clock);
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EZeroUnits)]
fun zero_units_are_refused() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    let c = coin(&mut s, 5000);
    let mut m = s.take_shared<Merchant>();
    chain_payments::pay<SUI>(&mut m, b"s1", 5000, 0, MONTH_MS, b"acct1", 61_000, b"n1", vectors::basic_signature(), c, &clock, s.ctx());
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::ETooManyUnits)]
fun more_units_than_the_limit_are_refused() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    let c = coin(&mut s, 50_000);
    let mut m = s.take_shared<Merchant>();
    chain_payments::pay<SUI>(&mut m, b"s1", 50_000, 13, MONTH_MS, b"acct1", 61_000, b"n1", vectors::basic_signature(), c, &clock, s.ctx());
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadIdentifier)]
fun an_empty_session_is_refused() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    let c = coin(&mut s, 5000);
    let mut m = s.take_shared<Merchant>();
    chain_payments::pay<SUI>(&mut m, b"", 5000, 2, MONTH_MS, b"acct1", 61_000, b"n1", vectors::basic_signature(), c, &clock, s.ctx());
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EWrongVersion)]
fun an_old_merchant_version_refuses_payments() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    let c = coin(&mut s, 5000);
    let mut m = s.take_shared<Merchant>();
    chain_payments::set_version_for_testing(&mut m, 0);
    chain_payments::pay<SUI>(&mut m, b"s1", 5000, 2, MONTH_MS, b"acct1", 61_000, b"n1", vectors::basic_signature(), c, &clock, s.ctx());
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EWrongVersion)]
fun an_old_merchant_version_refuses_governance() {
    let (mut s, _clock) = setup();
    s.next_tx(OWNER);
    let cap = s.take_from_sender<MerchantCap>();
    let mut m = s.take_shared<Merchant>();
    chain_payments::set_version_for_testing(&mut m, 0);
    chain_payments::set_paused(&cap, &mut m, true);
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadLimits)]
fun set_limits_checks_the_ceiling() {
    let (mut s, _clock) = setup();
    s.next_tx(OWNER);
    let cap = s.take_from_sender<MerchantCap>();
    let mut m = s.take_shared<Merchant>();
    chain_payments::set_limits(&cap, &mut m, 12, 121 * MONTH_MS);
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadIdentifier)]
fun a_too_long_session_is_refused() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    let c = coin(&mut s, 5000);
    let mut m = s.take_shared<Merchant>();
    chain_payments::pay<SUI>(&mut m, x"6161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161", 5000, 2, MONTH_MS, b"acct1", 61_000, b"n1", vectors::basic_signature(), c, &clock, s.ctx());
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadIdentifier)]
fun an_empty_nonce_is_refused() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    let c = coin(&mut s, 5000);
    let mut m = s.take_shared<Merchant>();
    chain_payments::pay<SUI>(&mut m, b"s1", 5000, 2, MONTH_MS, b"acct1", 61_000, b"", vectors::basic_signature(), c, &clock, s.ctx());
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadIdentifier)]
fun a_too_long_nonce_is_refused() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    let c = coin(&mut s, 5000);
    let mut m = s.take_shared<Merchant>();
    chain_payments::pay<SUI>(&mut m, b"s1", 5000, 2, MONTH_MS, b"acct1", 61_000, x"6161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161", vectors::basic_signature(), c, &clock, s.ctx());
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadIdentifier)]
fun a_too_long_reference_is_refused() {
    let (mut s, clock) = setup();
    s.next_tx(PAYER);
    let c = coin(&mut s, 5000);
    let mut m = s.take_shared<Merchant>();
    chain_payments::pay<SUI>(&mut m, b"s1", 5000, 2, MONTH_MS, x"6161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161", 61_000, b"n1", vectors::basic_signature(), c, &clock, s.ctx());
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadLimits)]
fun zero_max_units_is_refused() {
    let mut s = ts::begin(OWNER);
    let cap = chain_payments::create_merchant(RECIPIENT, vectors::public_key(), 0, MONTH_MS, s.ctx());
    chain_payments::destroy_cap_for_testing(cap);
    abort 99
}

#[test, expected_failure(abort_code = chain_payments::EBadLimits)]
fun zero_max_ahead_is_refused() {
    let mut s = ts::begin(OWNER);
    let cap = chain_payments::create_merchant(RECIPIENT, vectors::public_key(), 12, 0, s.ctx());
    chain_payments::destroy_cap_for_testing(cap);
    abort 99
}
