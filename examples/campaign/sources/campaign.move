module crowdfunding::campaign {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::event;
    use std::vector;

    /// Represents a crowdfunding campaign
    public struct Campaign<phantom TI, phantom TR> has key, store {
        id: UID,
        target_amount: u64,
        raised_amount: Balance<TI>,
        contributors_count: u64,
        receiver: address,
    }

    /// Whitelist for controlling access to the campaign
    public struct Whitelist has key, store {
        id: UID,
        campaign_id: ID,
        allowed_addresses: vector<address>,
    }

    /// Admin capability for managing campaigns
    public struct AdminCap has key, store {
        id: UID,
    }

    /// Event emitted when a contribution is made
    public struct ContributedToCampaign has copy, drop {
        campaign_id: ID,
        contributor: address,
        amount: u64,
    }

    /// Creates a new crowdfunding campaign and its corresponding whitelist
    public entry fun create_campaign<TI, TR>(
        _: &AdminCap,
        campaign_id: ID,
        target_amount: u64,
        receiver: address,
        ctx: &mut TxContext
    ) {
        let campaign_id_obj = object::new(ctx);
        let campaign_uid_id = object::uid_to_inner(&campaign_id_obj);

        let campaign = Campaign<TI, TR> {
            id: campaign_id_obj,
            target_amount,
            raised_amount: balance::zero<TI>(),
            contributors_count: 0,
            receiver,
        };

        let whitelist = Whitelist {
            id: object::new(ctx),
            campaign_id: campaign_uid_id,
            allowed_addresses: vector::empty(),
        };

        // Store the IDs before moving the objects
        let campaign_id = object::uid_to_inner(&campaign.id);
        let whitelist_campaign_id = whitelist.campaign_id;

        transfer::share_object(campaign);
        transfer::share_object(whitelist);

        assert!(campaign_id == whitelist_campaign_id);
    }

    public entry fun contribute<TI>(
        campaign: &mut Campaign<TI, TI>,
        whitelist: &Whitelist,
        coin: &mut Coin<TI>,
        amount: u64,
        contributor: address,
        ctx: &mut TxContext
    ) {
    

        campaign.contributors_count = campaign.contributors_count + 1;

        // Extract the specified amount from the input coin
        let payment = coin::split(coin, amount, ctx);

        // Deposit the payment into the campaign's raised amount
        let payment_balance = coin::into_balance(payment);
        balance::join(&mut campaign.raised_amount, payment_balance);

        // Emit contribution event
        event::emit(ContributedToCampaign {
            campaign_id: object::uid_to_inner(&campaign.id),
            contributor,
            amount
        });
    }

    #[spec_only]
    use prover::prover::{ensures, requires};

    #[spec(prove)]
    fun contribute_vulnerability_spec<TI>(
        campaign: &mut Campaign<TI, TI>,
        whitelist: &Whitelist,
        coin: &mut Coin<TI>,
        amount: u64,
        contributor: address,
        _ctx: &mut TxContext
    ) {
        let campaign_id = object::uid_to_inner(&campaign.id);
        let whitelist_id = whitelist.campaign_id;
        requires(campaign_id != whitelist_id);

        // 2. Record original state
        let initial_count = campaign.contributors_count;

        // Call contribute function
        contribute(campaign, whitelist, coin, amount, contributor, _ctx);

        // 4. Security property that SHOULD be true in a secure implementation:
        // "If campaign ID != whitelist ID, then contribution should not succeed"
        //
        // Since our implementation is vulnerable, this condition will FAIL,
        // proving that the vulnerability exists
        ensures(campaign.contributors_count == initial_count);
    }
} 