address marketplace {
/// Provides the ability to make collection offers to both Tokenv1 and Tokenv2 collections.
/// A collection offer allows an entity to buy up to N assets within a collection at their
/// specified amount. The amount offered is extracted from their account and stored at an
/// escrow. A seller can then exchange the token for the escrowed payment. If it is a
/// a tokenv2 or the recipient has enabled direct deposit, the token is immediately
/// transferred. If it is tokenv1 without direct deposit, it is stored in a container
/// until the recipient extracts it.
module bid {
    use std::error;
    use std::option::{Self};
    use std::signer;
    use std::string::String;

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::object::{Self, DeleteRef, Object};
    use aptos_framework::timestamp;

    use aptos_token::token as tokenv1;


    use marketplace::fee_schedule::{Self, FeeSchedule};
    use marketplace::listing::{Self};

    #[test_only]
    friend marketplace::collection_offer_tests;

    /// No collection offer defined.
    const ENO_BID_OFFER: u64 = 1;
    /// No coin offer defined.
    const ENO_COIN_OFFER: u64 = 2;
    /// No token offer defined.
    const ENO_TOKEN_OFFER: u64 = 3;
    /// This is not the owner of the collection offer.
    const ENOT_OWNER: u64 = 4;
    /// The offered token is not within the expected collection.
    const EINCORRECT_COLLECTION: u64 = 5;
    /// The collection offer has expired.
    const EEXPIRED: u64 = 6;
    struct Bid has key {
        bidder: address,
        creator_address: address,
        collection_name: String,
        token_name: String,
        fee_schedule: Object<FeeSchedule>,
        property_version: u64,
        expiration_time: u64,
        delete_ref: DeleteRef,
        events: EventHandle<BidOfferEvent>
    }

    /// An event for when a token bid has been met.
    struct BidOfferEvent has drop, store {
        seller: address,
        price: u64,
        royalties: u64,
        commission: u64,
    }
    struct CoinOffer<phantom CoinType> has key {
        coins: Coin<CoinType>,
    }
    public entry fun bid_for_tokenv1<CoinType>(
        bidder: &signer,
        creator_address: address,
        collection_name: String,
        token_name: String,
        fee_schedule: Object<FeeSchedule>,
        bid_amount: u64,
        property_version: u64,
        expiration_time: u64,
    ) {
        let constructor_ref = object::create_object_from_account(bidder);
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);
        let offer_signer = object::generate_signer(&constructor_ref);
        let coins = coin::withdraw<CoinType>(bidder, bid_amount);
        let offer = Bid {
            bidder:signer::address_of(bidder),
            creator_address,
            collection_name,
            token_name,
            fee_schedule,
            property_version,
            expiration_time,
            delete_ref:object::generate_delete_ref(&constructor_ref),
            events: object::new_event_handle(&offer_signer),
        };
        move_to(&offer_signer, offer);
        move_to(&offer_signer, CoinOffer { coins });
    }
    public entry fun sell_for_tokenv1<CoinType>(
        seller: &signer,
        object: Object<Bid>,
    ) acquires Bid,CoinOffer{
        let bid = borrow_global_mut<Bid>(object::object_address(&object));
        let token_id = tokenv1::create_token_id_raw(
            bid.creator_address,
            bid.collection_name,
            bid.token_name,
            bid.property_version,
        );
        let token = tokenv1::withdraw_token(seller, token_id, 1);
        let container = if (tokenv1::get_direct_transfer(bid.bidder)) {
            tokenv1::direct_deposit_with_opt_in(bid.bidder, token);
            option::none()
        } else {
            let container = listing::create_tokenv1_container_with_token(seller, token);
            object::transfer(seller, container, bid.bidder);
            option::some(container)
        };
        let royalty = tokenv1::get_royalty(token_id);
        settle_payments<CoinType>(
            signer::address_of(seller),
            tokenv1::get_royalty_payee(&royalty),
            tokenv1::get_royalty_denominator(&royalty),
            tokenv1::get_royalty_numerator(&royalty),
            object::object_address(&object)
        );
    }
    inline fun settle_payments<CoinType>(
        seller: address,
        royalty_payee: address,
        royalty_denominator: u64,
        royalty_numerator: u64,
        object: address
    )acquires Bid,CoinOffer{
        let bid_details = borrow_global_mut<Bid>(object);
        let bid_amount = borrow_global_mut<CoinOffer<CoinType>>(object);
        assert!(
            timestamp::now_seconds() < bid_details.expiration_time,
            error::invalid_state(EEXPIRED),
        );
        let total_amount = coin::value(&bid_amount.coins);
        let coins = coin::extract_all(&mut bid_amount.coins);

        let royalty_charge = total_amount * royalty_numerator / royalty_denominator;
        let royalties = coin::extract(&mut coins, royalty_charge);
        coin::deposit(royalty_payee, royalties);

        let fee_schedule = bid_details.fee_schedule;
        let commission_charge = fee_schedule::commission(fee_schedule, total_amount);
        let commission = coin::extract(&mut coins, commission_charge);
        coin::deposit(fee_schedule::fee_address(fee_schedule), commission);

        coin::deposit(seller, coins);

        let event = BidOfferEvent {
            seller,
            price: total_amount,
            royalties: royalty_charge,
            commission: commission_charge,
        };
        event::emit_event(&mut bid_details.events, event);
    }
    public entry fun cancel<CoinType>(
        bidder: &signer,
        object: Object<Bid>,
    ) acquires CoinOffer, Bid {
        let object_address = object::object_address(&object);
        assert!(
            exists<Bid>(object_address),
            error::not_found(ENO_BID_OFFER),
        );
        assert!(
            object::is_owner(object, signer::address_of(bidder)),
            error::permission_denied(ENOT_OWNER),
        );

        cleanup<CoinType>(object_address,object);
    }
    inline fun cleanup<CoinType>(
        object_address: address,
        object: Object<Bid>
    ) acquires CoinOffer, Bid{
        let CoinOffer<CoinType> { coins } = move_from(object_address);
        coin::deposit(object::owner(object), coins);

        let Bid {
            bidder:_,
            creator_address:_,
            collection_name: _,
            token_name: _,
            fee_schedule: _,
            property_version: _,
            expiration_time: _,
            delete_ref,
            events
        } = move_from(object_address);
        object::delete(delete_ref);
        event::destroy_handle(events);
    }
}
}