address marketplace {
/// Defines a single listing or an item for sale or auction. This is an escrow service that
/// enables two parties to exchange one asset for another.
/// Each listing has the following properties:
/// * FeeSchedule specifying payment flows
/// * Owner or the person that can end the sale or auction
/// * Optional buy it now price
/// * Ending time at which point it can be claimed by the highest bidder or left in escrow.
/// * For auctions, the minimum bid rate and optional increase in duration of the auction if bids
///   are made toward the end of the auction.
module coin_listing {
    use std::error;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self,String};
    use std::vector;

    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::object::{Self, ConstructorRef, Object, ObjectCore};
    use aptos_framework::timestamp;
    use aptos_framework::aptos_account;

    use marketplace::fee_schedule::{Self, FeeSchedule};
    use marketplace::listing::{Self, Listing};
    use marketplace::events;

    #[test_only]
    friend marketplace::listing_tests;

    /// There exists no listing.
    const ENO_LISTING: u64 = 1;
    /// This is an auction without buy it now.
    const ENO_BUY_IT_NOW: u64 = 2;
    /// The proposed bid is insufficient.
    const EBID_TOO_LOW: u64 = 3;
    /// The auction has not yet ended.
    const EAUCTION_NOT_ENDED: u64 = 4;
    /// The auction has already ended.
    const EAUCTION_ENDED: u64 = 5;
    /// The entity is not the seller.
    const ENOT_SELLER: u64 = 6;

    const FIXED_PRICE_TYPE: vector<u8> = b"fixed price";

    // Core data structures

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// Fixed-price market place listing.
    struct FixedPriceListing<phantom CoinType> has key {
        /// The price to purchase the item up for listing.
        price: u64,
    }

    /// An event triggered upon the sale of an item. Note, the amount given to the seller is the
    /// price - commission - royalties. In the case there was no sale, purchaser is equal to seller
    /// and the amounts will all be zero.
    struct PurchaseEvent has drop, store {
        purchaser: address,
        price: u64,
        commission: u64,
        royalties: u64,
    }

    // Init functions

    public entry fun init_fixed_price<CoinType>(
        seller: &signer,
        object: Object<ObjectCore>,
        fee_schedule: Object<FeeSchedule>,
        price: u64,
    ) {
        init_fixed_price_internal<CoinType>(seller, object, fee_schedule, price);
    }

    public entry fun init_fixed_price_many<CoinType>(
        seller: &signer,
        object: vector<Object<ObjectCore>>,
        fee_schedule: Object<FeeSchedule>,
        price: vector<u64>,
    ) {
        let i = 0;
        while (i < vector::length(&price)){
            init_fixed_price_internal<CoinType>(seller,*vector::borrow(&object,i), fee_schedule,*vector::borrow(&price,i));
            i=i+1
        }
    }
    public(friend) fun init_fixed_price_internal<CoinType>(
        seller: &signer,
        object: Object<ObjectCore>,
        fee_schedule: Object<FeeSchedule>,
        price: u64,
    ): Object<Listing> {
        let (listing_signer, constructor_ref) = init<CoinType>(
            seller,
            object,
            fee_schedule,
            price,
        );

        let fixed_price_listing = FixedPriceListing<CoinType> {
            price,
        };
        move_to(&listing_signer, fixed_price_listing);

        let listing = object::object_from_constructor_ref(&constructor_ref);

        events::emit_listing_placed(
            fee_schedule,
            string::utf8(FIXED_PRICE_TYPE),
            object::object_address(&listing),
            signer::address_of(seller),
            price,
            listing::token_metadata(listing),
        );

        listing
    }
    public entry fun init_fixed_price_for_tokenv1<CoinType>(
        seller: &signer,
        token_creator: address,
        token_collection: String,
        token_name: String,
        token_property_version: u64,
        fee_schedule: Object<FeeSchedule>,
        price: u64,
    ) {
        init_fixed_price_for_tokenv1_internal<CoinType>(
            seller,
            token_creator,
            token_collection,
            token_name,
            token_property_version,
            fee_schedule,
            price,
        );
    }
    public entry fun init_fixed_price_for_tokenv1_many<CoinType>(
        seller: &signer,
        token_creator: address,
        token_collection: String,
        token_name: vector<String>,
        token_property_version: u64,
        fee_schedule: Object<FeeSchedule>,
        price: vector<u64>,
    ) {
        let i = 0;
        while (i < vector::length(&price)){
            init_fixed_price_for_tokenv1_internal<CoinType>(seller,token_creator,token_collection,*vector::borrow(&token_name,i), token_property_version,fee_schedule,*vector::borrow(&price,i));
            i=i+1
        }
    }
    public(friend) fun init_fixed_price_for_tokenv1_internal<CoinType>(
        seller: &signer,
        token_creator: address,
        token_collection: String,
        token_name: String,
        token_property_version: u64,
        fee_schedule: Object<FeeSchedule>,
        price: u64,
    ): Object<Listing> {
        let object = listing::create_tokenv1_container(
            seller,
            token_creator,
            token_collection,
            token_name,
            token_property_version,
        );
        init_fixed_price_internal<CoinType>(
            seller,
            object::convert(object),
            fee_schedule,
            price,
        )
    }

    inline fun init<CoinType>(
        seller: &signer,
        object: Object<ObjectCore>,
        fee_schedule: Object<FeeSchedule>,
        initial_price: u64,
    ): (signer, ConstructorRef) {
        aptos_account::transfer_coins<CoinType>(
            seller,
            fee_schedule::fee_address(fee_schedule),
            fee_schedule::listing_fee(fee_schedule, initial_price),
        );

        listing::init(seller, object, fee_schedule)
    }

public entry fun purchase_many<CoinType>(
        purchaser: &signer,
        object: vector<Object<Listing>>
    ) acquires FixedPriceListing {
        let i = 0;
        while (i < vector::length(&object)){
            purchase<CoinType>(purchaser,*vector::borrow(&object,i));
            i=i+1
        }
    }

    // Mutators

    /// Purchase outright an item from an auction or a fixed price listing.
    public entry fun purchase<CoinType>(
        purchaser: &signer,
        object: Object<Listing>,
    ) acquires FixedPriceListing {
        let listing_addr = listing::assert_started(&object);

        // Retrieve the purchase price if the auction has buy it now or this is a fixed listing.
        let (price) = if (exists<FixedPriceListing<CoinType>>(listing_addr)) {
            let FixedPriceListing {
                price,
            } = move_from<FixedPriceListing<CoinType>>(listing_addr);
            price
        } else {
            // This should just be an abort but the compiler errors.
            abort(error::not_found(ENO_LISTING))
        };

        let coins = coin::withdraw<CoinType>(purchaser, price);

        complete_purchase(purchaser, object, coins, string::utf8(FIXED_PRICE_TYPE))
    }

    public entry fun end_fixed_price_many<CoinType>(
        purchaser: &signer,
        object: vector<Object<Listing>>
    ) acquires FixedPriceListing {
        let i = 0;
        while (i < vector::length(&object)){
            end_fixed_price<CoinType>(purchaser,*vector::borrow(&object,i));
            i=i+1
        }
    }
    /// End a fixed price listing early.
    public entry fun end_fixed_price<CoinType>(
        seller: &signer,
        object: Object<Listing>,
    ) acquires FixedPriceListing {
        let token_metadata = listing::token_metadata(object);

        let expected_seller_addr = signer::address_of(seller);
        let (actual_seller_addr, fee_schedule) = listing::close(object, seller);
        assert!(expected_seller_addr == actual_seller_addr, error::permission_denied(ENOT_SELLER));

        let listing_addr = object::object_address(&object);
        assert!(exists<FixedPriceListing<CoinType>>(listing_addr), error::not_found(ENO_LISTING));
        let FixedPriceListing {
            price,
        } = move_from<FixedPriceListing<CoinType>>(listing_addr);

        events::emit_listing_canceled(
            fee_schedule,
            string::utf8(FIXED_PRICE_TYPE),
            listing_addr,
            actual_seller_addr,
            price,
            token_metadata,
        );
    }

    public entry fun update_fixed_price<CoinType>(
        seller: &signer,
        object: Object<Listing>,
        price: u64
    ) acquires FixedPriceListing {
        let expected_seller_addr = signer::address_of(seller);
        let actual_seller_addr= listing::seller(object);
        assert!(expected_seller_addr == actual_seller_addr, error::permission_denied(ENOT_SELLER));

        let listing_addr = object::object_address(&object);
        assert!(exists<FixedPriceListing<CoinType>>(listing_addr), error::not_found(ENO_LISTING));
        let listing_price = borrow_global_mut<FixedPriceListing<CoinType>>(listing_addr);
        listing_price.price = price;
        events::emit_listing_placed(
            listing::fee_schedule(object),
            string::utf8(FIXED_PRICE_TYPE),
            object::object_address(&object),
            signer::address_of(seller),
            price,
            listing::token_metadata(object),
        );
    }
    public entry fun update_fixed_price_many<CoinType>(
        seller: &signer,
        object: vector<Object<Listing>>,
        price: vector<u64>
    )acquires FixedPriceListing{
        let i = 0;
        while (i < vector::length(&price)){
            update_fixed_price<CoinType>(seller,*vector::borrow(&object,i),*vector::borrow(&price,i));
            i=i+1
        }
    }
    public entry fun list_and_update_fixed_price_tokenv1_many<CoinType>(
        seller: &signer,
        token_creator: address,
        token_collection: String,
        token_name: vector<String>,
        token_property_version: u64,
        fee_schedule: Object<FeeSchedule>,
        price: vector<u64>,
        listing_price: vector<u64>,
        listed_object: vector<Object<Listing>>,
        updated_price: vector<u64>
    )acquires FixedPriceListing{
        init_fixed_price_for_tokenv1_many<CoinType>(seller,token_creator,token_collection,token_name,token_property_version,fee_schedule,price);
        update_fixed_price_many<CoinType>(seller,listed_object,updated_price)
    }
    public entry fun list_and_update_fixed_price_many<CoinType>(
        seller: &signer,
        object: vector<Object<ObjectCore>>,
        fee_schedule: Object<FeeSchedule>,
        price: vector<u64>,
        listing_price: vector<u64>,
        listed_object: vector<Object<Listing>>,
        updated_price: vector<u64>
    )acquires FixedPriceListing{
        init_fixed_price_many<CoinType>(seller,object,fee_schedule,price);
        update_fixed_price_many<CoinType>(seller,listed_object,updated_price)
    }
    inline fun complete_purchase<CoinType>(
        purchaser: &signer,
        object: Object<Listing>,
        coins: Coin<CoinType>,
        type: String,
    ) {
        let token_metadata = listing::token_metadata(object);

        let price = coin::value(&coins);
        let (royalty_addr, royalty_charge) = listing::compute_royalty(object, price);
        let (seller, fee_schedule) = listing::close(object, purchaser);

        let commission_charge = fee_schedule::commission(fee_schedule, price);
        let commission = coin::extract(&mut coins, commission_charge);
        aptos_account::deposit_coins(fee_schedule::fee_address(fee_schedule), commission);

        if (royalty_charge != 0) {
            let royalty = coin::extract(&mut coins, royalty_charge);
            aptos_account::deposit_coins(royalty_addr, royalty);
        };

        aptos_account::deposit_coins(seller, coins);

        events::emit_listing_filled(
            fee_schedule,
            type,
            object::object_address(&object),
            seller,
            signer::address_of(purchaser),
            price,
            commission_charge,
            royalty_charge,
            token_metadata,
        );
    }

    // View

    #[view]
    public fun price<CoinType>(
        object: Object<Listing>,
    ): Option<u64> acquires FixedPriceListing {
        let listing_addr = object::object_address(&object);
        if (exists<FixedPriceListing<CoinType>>(listing_addr)) {
            let fixed_price = borrow_global<FixedPriceListing<CoinType>>(listing_addr);
            option::some(fixed_price.price)
        } 
        else {
            // This should just be an abort but the compiler errors.
            assert!(false, error::not_found(ENO_LISTING));
            option::none()
        }
    }


    inline fun borrow_fixed_price<CoinType>(
        object: Object<Listing>,
    ): &FixedPriceListing<CoinType> acquires FixedPriceListing {
        let obj_addr = object::object_address(&object);
        assert!(exists<FixedPriceListing<CoinType>>(obj_addr), error::not_found(ENO_LISTING));
        borrow_global<FixedPriceListing<CoinType>>(obj_addr)
    }
}
}
