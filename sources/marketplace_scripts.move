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
module marketplace_scripts {
    use marketplace::coin_listing::{Self};
    use std::vector;
    use aptos_framework::object::{Self, ConstructorRef, Object, ObjectCore};
    use marketplace::listing::{Self, Listing};
    use marketplace::fee_schedule::{Self, FeeSchedule};

    public entry fun purchase_many<CoinType>(
            purchaser: &signer,
            object: vector<address>
        ){
            let i = 0;
            while (i < vector::length(&object)){
                let obj = object::address_to_object<Listing>(*vector::borrow(&object, i));
                coin_listing::purchase<CoinType>(purchaser,obj);
                i=i+1
            }
        }
    public entry fun init_fixed_price_many<CoinType>(
        seller: &signer,
        object: vector<address>,
        fee_schedule: Object<FeeSchedule>,
        price: vector<u64>,
    ) {
        let i = 0;
        while (i < vector::length(&price)){
            let obj = object::address_to_object<ObjectCore>(*vector::borrow(&object, i));
            coin_listing::init_fixed_price<CoinType>(seller,obj, fee_schedule,*vector::borrow(&price,i));
            i=i+1
        }
    }
    public entry fun end_fixed_price_many<CoinType>(
        purchaser: &signer,
        object: vector<address>
    ){
        let i = 0;
        while (i < vector::length(&object)){
            let obj = object::address_to_object<Listing>(*vector::borrow(&object, i));
            coin_listing::end_fixed_price<CoinType>(purchaser,obj);
            i=i+1
        }
    }
}
}