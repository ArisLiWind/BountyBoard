module BountyBoard::bountyboard {
    use std::vector;
    use sui::coin::{self, Coin};
    use sui::event;
    use sui::object::{UID, id, UID};
    use sui::transfer;
    use sui::tx_context::{TxContext, new_tx_context};
    use sui::balance;

    // 核心变量 1：VisibilityScope
    struct VisibilityScope has copy, drop, store {
        kind: u8,
    }

    public fun visibility_self(): VisibilityScope { VisibilityScope { kind: 0 } }
    public fun visibility_alliance(): VisibilityScope { VisibilityScope { kind: 1 } }
    public fun visibility_global(): VisibilityScope { VisibilityScope { kind: 2 } }

    public fun is_self(scope: &VisibilityScope): bool { scope.kind == 0 }
    public fun is_alliance(scope: &VisibilityScope): bool { scope.kind == 1 }
    public fun is_global(scope: &VisibilityScope): bool { scope.kind == 2 }

    // 核心变量 2：BountyTarget
    struct BountyTarget has copy, drop, store {
        kind: u8,
    }

    public fun target_playership(): BountyTarget { BountyTarget { kind: 0 } }
    public fun target_structure(): BountyTarget { BountyTarget { kind: 1 } }
    public fun target_hybrid(): BountyTarget { BountyTarget { kind: 2 } }

    public fun is_playership(target: &BountyTarget): bool { target.kind == 0 }
    public fun is_structure(target: &BountyTarget): bool { target.kind == 1 }
    public fun is_hybrid(target: &BountyTarget): bool { target.kind == 2 }

    // 核心变量 3：RewardDistribution
    struct RewardDistribution has copy, drop, store {
        kind: u8,
    }

    public fun distribution_damageratio(): RewardDistribution { RewardDistribution { kind: 0 } }
    public fun distribution_lasthit(): RewardDistribution { RewardDistribution { kind: 1 } }
    public fun distribution_custom(): RewardDistribution { RewardDistribution { kind: 2 } }

    public fun is_damageratio(rule: &RewardDistribution): bool { rule.kind == 0 }
    public fun is_lasthit(rule: &RewardDistribution): bool { rule.kind == 1 }
    public fun is_custom(rule: &RewardDistribution): bool { rule.kind == 2 }

    // 悬赏对象结构
    struct Bounty<RewardType> has key {
        id: UID,
        publisher: address,
        target_uid: address,
        visibility: VisibilityScope,
        target_type: BountyTarget,
        distribution: RewardDistribution,
        is_open: bool,
        deposited: Coin<RewardType>,
        total_damage: u128,
        last_hit: Option<address>,
        custom_recipients: vector<address>,
        created_at: u64,
        updated_at: u64,
    }

    struct BountyCreatedEvent has drop, store {
        bounty_id: UID,
        publisher: address,
        target_uid: address,
        visibility: u8,
        target_type: u8,
        distribution: u8,
        amount: u64,
    }

    struct BountySettledEvent has drop, store {
        bounty_id: UID,
        total_paid: u64,
        distribution: u8,
        success: bool,
    }

    struct BountyEventHandles has key {
        id: UID,
        created: event::EventHandle<BountyCreatedEvent>,
        settled: event::EventHandle<BountySettledEvent>,
    }

    public fun init(ctx: &mut TxContext): BountyEventHandles {
        let created = event::new_event_handle<BountyCreatedEvent>(ctx);
        let settled = event::new_event_handle<BountySettledEvent>(ctx);
        BountyEventHandles {
            id: new_uid(ctx),
            created,
            settled,
        }
    }

    fun new_uid(ctx: &mut TxContext): UID {
        UID::new(ctx)
    }

    // 创建悬赏
    public entry fun create_bounty<RewardType>(
        publisher: address,
        target_uid: address,
        visibility: VisibilityScope,
        target_type: BountyTarget,
        distribution: RewardDistribution,
        reward: Coin<RewardType>,
        now: u64,
        event_handle: &mut BountyEventHandles,
        ctx: &mut TxContext
    ): Bounty<RewardType> {
        let bounty = Bounty {
            id: new_uid(ctx),
            publisher,
            target_uid,
            visibility,
            target_type,
            distribution,
            is_open: true,
            deposited: reward,
            total_damage: 0,
            last_hit: Option::none<address>(),
            custom_recipients: vector::empty<address>(),
            created_at: now,
            updated_at: now,
        };

        let value = coin::value(&bounty.deposited);
        event::emit_event(&mut event_handle.created, BountyCreatedEvent {
            bounty_id: id(&bounty.id),
            publisher,
            target_uid,
            visibility: visibility.kind,
            target_type: target_type.kind,
            distribution: distribution.kind,
            amount: value,
        });

        bounty
    }

    // 记录伤害与最后一击信息
    public entry fun report_progress<RewardType>(
        bounty: &mut Bounty<RewardType>,
        add_damage: u128,
        maybe_last_hit: Option<address>,
        now: u64
    ) {
        assert!(bounty.is_open, 1);
        bounty.total_damage = bounty.total_damage + add_damage;
        if (Option::is_some(&maybe_last_hit)) {
            bounty.last_hit = maybe_last_hit;
        }
        bounty.updated_at = now;
    }

    // 设置自定义收件人（发布者可调用）
    public entry fun set_custom_recipients<RewardType>(
        bounty: &mut Bounty<RewardType>,
        requester: address,
        recipients: vector<address>,
        now: u64
    ) {
        assert!(bounty.publisher == requester, 2);
        assert!(bounty.is_open, 3);
        bounty.custom_recipients = recipients;
        bounty.updated_at = now;
    }

    // 核心：结算悬赏
    public entry fun settle_bounty<RewardType>(
        bounty: &mut Bounty<RewardType>,
        target_killed: bool,
        attackers: vector<(address, u128)>,
        now: u64,
        event_handle: &mut BountyEventHandles,
        ctx: &mut TxContext
    ): vector<Coin<RewardType>> {
        assert!(bounty.is_open, 4);
        assert!(target_killed, 5);

        let mut out_coins = vector::empty<Coin<RewardType>>();
        let total = bounty.total_damage;
        let reward_coin = coin::extract(&mut bounty.deposited, coin::value(&bounty.deposited));
        assert!(coin::value(&reward_coin) > 0, 6);

        if (is_damageratio(&bounty.distribution)) {
            assert!(total > 0, 7);
            let total_amount = coin::value(&reward_coin);
            let mut rest = total_amount;

            let mut i = 0;
            while (i < vector::length(&attackers)) {
                let (attacker, dmg) = *vector::borrow(&attackers, i);
                if (dmg > 0) {
                    let share = (total_amount * dmg) / total;
                    if (share > 0) {
                        let part = coin::split(&mut reward_coin, share);
                        out_coins = vector::push_back(out_coins, part);
                        rest = rest - share;
                    }
                }
                i = i + 1;
            }

            if (rest > 0) {
                let extra = coin::split(&mut reward_coin, rest);
                out_coins = vector::push_back(out_coins, extra);
            }
        } else if (is_lasthit(&bounty.distribution)) {
            let attacker_addr = Option::borrow(&bounty.last_hit);
            assert!(*attacker_addr != 0x0, 8);
            out_coins = vector::push_back(out_coins, reward_coin);
        } else {
            // Custom: 平均分配给指定自定义列表，若空则退回发布者
            let count = vector::length(&bounty.custom_recipients);
            if (count == 0) {
                out_coins = vector::push_back(out_coins, reward_coin);
            } else {
                let total_amount = coin::value(&reward_coin);
                let per = total_amount / (count as u64);
                let mut remain = total_amount;
                let mut j = 0;
                while (j < count) {
                    let part = if (j + 1 == count) {
                        coin::split(&mut reward_coin, remain)
                    } else {
                        coin::split(&mut reward_coin, per)
                    };
                    out_coins = vector::push_back(out_coins, part);
                    remain = remain - coin::value(&part);
                    j = j + 1;
                }
            }
        }

        bounty.is_open = false;
        bounty.updated_at = now;

        let paid = coin::value(&coin::join_all(out_coins.clone()));

        event::emit_event(&mut event_handle.settled, BountySettledEvent {
            bounty_id: id(&bounty.id),
            total_paid: paid,
            distribution: bounty.distribution.kind,
            success: true,
        });

        out_coins
    }

    // Helper for join all coins in vector
    fun join_all<RewardType>(coins: vector<Coin<RewardType>>): Coin<RewardType> {
        let mut i = 0;
        let len = vector::length(&coins);
        assert!(len > 0, 9);
        let mut acc = coin::extract(&mut vector::borrow_mut(&coins, 0), coin::value(vector::borrow(&coins,0)));
        // NOTE: above line unsafe because borrow_mut and borrow, simplified for illustration.
        // in real code请用另一种合并实现。
        acc
    }

    #[test]
    public fun test_create_and_settle() {
        let mut ctx = new_tx_context();
        let mut handles = init(&mut ctx);
        let publisher = @0x1;
        let target = @0x2;
        let reward = coin::mint<0x2::sui::SUI>(100, &mut ctx); // 伪代码，按实际Coin模块

        let mut bounty = create_bounty(
            publisher,
            target,
            visibility_global(),
            target_playership(),
            distribution_lasthit(),
            reward,
            1000,
            &mut handles,
            &mut ctx
        );

        report_progress(&mut bounty, 100, Option::some<address>(@0x3), 1010);
        let payouts = settle_bounty(&mut bounty, true, vector::empty<(address,u128)>(), 1020, &mut handles, &mut ctx);

        assert!(!bounty.is_open, 11);
        assert!(vector::length(&payouts) == 1, 12);
    }
}
