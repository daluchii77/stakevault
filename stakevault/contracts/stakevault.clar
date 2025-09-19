;; Stake Vault - Advanced Staking System with Compound Rewards
;; Tier-based staking protocol with dynamic APY and governance benefits

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-locked-period (err u104))
(define-constant err-already-staked (err u105))
(define-constant err-not-staked (err u106))
(define-constant err-paused (err u107))
(define-constant err-invalid-tier (err u108))
(define-constant err-max-stakers (err u109))
(define-constant err-zero-rewards (err u110))

;; Constants for tiers and rewards
(define-constant min-stake-amount u1000000) ;; 1 STX minimum
(define-constant bronze-threshold u10000000) ;; 10 STX
(define-constant silver-threshold u50000000) ;; 50 STX
(define-constant gold-threshold u100000000) ;; 100 STX
(define-constant platinum-threshold u500000000) ;; 500 STX

;; APY rates per tier (in basis points, 100 = 1%)
(define-constant bronze-apy u500) ;; 5% APY
(define-constant silver-apy u750) ;; 7.5% APY
(define-constant gold-apy u1000) ;; 10% APY
(define-constant platinum-apy u1500) ;; 15% APY

;; Lock periods (in blocks)
(define-constant lock-period-short u144) ;; ~1 day
(define-constant lock-period-medium u1008) ;; ~1 week
(define-constant lock-period-long u4320) ;; ~30 days

;; Data Variables
(define-data-var total-staked uint u0)
(define-data-var total-rewards-distributed uint u0)
(define-data-var reward-pool uint u0)
(define-data-var staker-count uint u0)
(define-data-var max-stakers uint u10000)
(define-data-var paused bool false)
(define-data-var compound-enabled bool true)
(define-data-var emergency-withdraw-enabled bool false)
(define-data-var base-apy uint u500) ;; 5% base APY

;; Data Maps
(define-map stakes
    principal
    {
        amount: uint,
        reward-debt: uint,
        start-block: uint,
        lock-until: uint,
        tier: (string-ascii 10),
        last-claim-block: uint,
        total-earned: uint,
        compound-count: uint
    }
)

(define-map user-stats
    principal
    {
        total-staked-lifetime: uint,
        total-rewards-earned: uint,
        stake-count: uint,
        highest-tier-reached: (string-ascii 10),
        referrals: uint
    }
)

(define-map referrals
    principal
    principal ;; referrer
)

(define-map tier-multipliers
    (string-ascii 10)
    uint
)

;; Initialize tier multipliers
(map-set tier-multipliers "bronze" u100)
(map-set tier-multipliers "silver" u150)
(map-set tier-multipliers "gold" u200)
(map-set tier-multipliers "platinum" u300)

;; Private Functions
(define-private (get-tier (amount uint))
    (if (>= amount platinum-threshold)
        "platinum"
        (if (>= amount gold-threshold)
            "gold"
            (if (>= amount silver-threshold)
                "silver"
                (if (>= amount bronze-threshold)
                    "bronze"
                    "basic"))))
)

(define-private (get-apy-for-tier (tier (string-ascii 10)))
    (if (is-eq tier "platinum")
        platinum-apy
        (if (is-eq tier "gold")
            gold-apy
            (if (is-eq tier "silver")
                silver-apy
                (if (is-eq tier "bronze")
                    bronze-apy
                    (var-get base-apy)))))
)

(define-private (calculate-rewards (principal-amount uint) (blocks uint) (apy uint))
    (let
        (
            ;; Calculate rewards: (amount * apy * blocks) / (365 * 144 * 10000)
            ;; Simplified for block-based calculation
            (annual-blocks u52560) ;; ~365 days in blocks
            (numerator (* (* principal-amount apy) blocks))
            (denominator (* annual-blocks u10000))
        )
        (/ numerator denominator)
    )
)

(define-private (min (a uint) (b uint))
    (if (< a b) a b)
)

;; Read-Only Functions
(define-read-only (get-stake (staker principal))
    (map-get? stakes staker)
)

(define-read-only (get-user-stats (user principal))
    (default-to
        {
            total-staked-lifetime: u0,
            total-rewards-earned: u0,
            stake-count: u0,
            highest-tier-reached: "none",
            referrals: u0
        }
        (map-get? user-stats user)
    )
)

(define-read-only (get-total-staked)
    (var-get total-staked)
)

(define-read-only (get-reward-pool)
    (var-get reward-pool)
)

(define-read-only (get-staker-count)
    (var-get staker-count)
)

(define-read-only (is-paused)
    (var-get paused)
)

(define-read-only (calculate-pending-rewards (staker principal))
    (match (map-get? stakes staker)
        stake-info
        (let
            (
                (blocks-staked (- u1 (get last-claim-block stake-info)))
                (tier-apy (get-apy-for-tier (get tier stake-info)))
                (rewards (calculate-rewards (get amount stake-info) blocks-staked tier-apy))
            )
            rewards
        )
        u0
    )
)

(define-read-only (get-user-tier (staker principal))
    (match (map-get? stakes staker)
        stake-info (get tier stake-info)
        "none"
    )
)

(define-read-only (get-lock-time-remaining (staker principal))
    (match (map-get? stakes staker)
        stake-info
        (if (> (get lock-until stake-info) u1)
            (- (get lock-until stake-info) u1)
            u0)
        u0
    )
)

;; Public Functions

;; Stake tokens with optional lock period for bonus rewards
(define-public (stake (amount uint) (lock-duration uint))
    (let
        (
            (staker tx-sender)
            (existing-stake (map-get? stakes staker))
            (tier (get-tier amount))
            (lock-until (+ u1 lock-duration))
            (current-stakers (var-get staker-count))
        )
        ;; Validations
        (asserts! (not (var-get paused)) err-paused)
        (asserts! (>= amount min-stake-amount) err-invalid-amount)
        (asserts! (is-none existing-stake) err-already-staked)
        (asserts! (< current-stakers (var-get max-stakers)) err-max-stakers)
        (asserts! (<= lock-duration lock-period-long) err-invalid-amount)
        (asserts! (>= (stx-get-balance staker) amount) err-insufficient-balance)
        
        ;; Transfer tokens to contract
        (try! (stx-transfer? amount staker (as-contract tx-sender)))
        
        ;; Create stake record
        (map-set stakes staker {
            amount: amount,
            reward-debt: u0,
            start-block: u1,
            lock-until: lock-until,
            tier: tier,
            last-claim-block: u1,
            total-earned: u0,
            compound-count: u0
        })
        
        ;; Update user stats
        (let
            (
                (current-stats (get-user-stats staker))
            )
            (map-set user-stats staker {
                total-staked-lifetime: (+ (get total-staked-lifetime current-stats) amount),
                total-rewards-earned: (get total-rewards-earned current-stats),
                stake-count: (+ (get stake-count current-stats) u1),
                highest-tier-reached: tier,
                referrals: (get referrals current-stats)
            })
        )
        
        ;; Update global stats
        (var-set total-staked (+ (var-get total-staked) amount))
        (var-set staker-count (+ current-stakers u1))
        
        (ok amount)
    )
)

;; Add to existing stake
(define-public (add-stake (additional-amount uint))
    (let
        (
            (staker tx-sender)
            (existing-stake (unwrap! (map-get? stakes staker) err-not-staked))
            (new-amount (+ (get amount existing-stake) additional-amount))
            (new-tier (get-tier new-amount))
        )
        ;; Validations
        (asserts! (not (var-get paused)) err-paused)
        (asserts! (> additional-amount u0) err-invalid-amount)
        (asserts! (>= (stx-get-balance staker) additional-amount) err-insufficient-balance)
        
        ;; Transfer additional tokens
        (try! (stx-transfer? additional-amount staker (as-contract tx-sender)))
        
        ;; Update stake with new amount and tier
        (map-set stakes staker 
            (merge existing-stake {
                amount: new-amount,
                tier: new-tier
            })
        )
        
        ;; Update stats
        (let
            (
                (current-stats (get-user-stats staker))
            )
            (map-set user-stats staker 
                (merge current-stats {
                    total-staked-lifetime: (+ (get total-staked-lifetime current-stats) additional-amount)
                })
            )
        )
        
        ;; Update total staked
        (var-set total-staked (+ (var-get total-staked) additional-amount))
        
        (ok new-amount)
    )
)

;; Claim rewards without unstaking
(define-public (claim-rewards)
    (let
        (
            (staker tx-sender)
            (stake-data (unwrap! (map-get? stakes staker) err-not-staked))
            (pending-rewards (calculate-pending-rewards staker))
        )
        ;; Validations
        (asserts! (not (var-get paused)) err-paused)
        (asserts! (> pending-rewards u0) err-zero-rewards)
        (asserts! (<= pending-rewards (var-get reward-pool)) err-insufficient-balance)
        
        ;; Transfer rewards
        (try! (as-contract (stx-transfer? pending-rewards tx-sender staker)))
        
        ;; Update stake record
        (map-set stakes staker 
            (merge stake-data {
                last-claim-block: u1,
                total-earned: (+ (get total-earned stake-data) pending-rewards)
            })
        )
        
        ;; Update stats
        (let
            (
                (current-stats (get-user-stats staker))
            )
            (map-set user-stats staker 
                (merge current-stats {
                    total-rewards-earned: (+ (get total-rewards-earned current-stats) pending-rewards)
                })
            )
        )
        
        ;; Update global stats
        (var-set reward-pool (- (var-get reward-pool) pending-rewards))
        (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) pending-rewards))
        
        (ok pending-rewards)
    )
)

;; Compound rewards back into stake
(define-public (compound-rewards)
    (let
        (
            (staker tx-sender)
            (stake-data (unwrap! (map-get? stakes staker) err-not-staked))
            (pending-rewards (calculate-pending-rewards staker))
            (new-amount (+ (get amount stake-data) pending-rewards))
            (new-tier (get-tier new-amount))
        )
        ;; Validations
        (asserts! (not (var-get paused)) err-paused)
        (asserts! (var-get compound-enabled) err-paused)
        (asserts! (> pending-rewards u0) err-zero-rewards)
        
        ;; Update stake with compounded amount
        (map-set stakes staker 
            (merge stake-data {
                amount: new-amount,
                tier: new-tier,
                last-claim-block: u1,
                total-earned: (+ (get total-earned stake-data) pending-rewards),
                compound-count: (+ (get compound-count stake-data) u1)
            })
        )
        
        ;; Update total staked (rewards become staked)
        (var-set total-staked (+ (var-get total-staked) pending-rewards))
        
        (ok new-amount)
    )
)

;; Unstake and claim all rewards
(define-public (unstake)
    (let
        (
            (staker tx-sender)
            (stake-data (unwrap! (map-get? stakes staker) err-not-staked))
            (amount (get amount stake-data))
            (pending-rewards (calculate-pending-rewards staker))
            (total-payout (+ amount pending-rewards))
        )
        ;; Validations
        (asserts! (not (var-get paused)) err-paused)
        (asserts! (>= u1 (get lock-until stake-data)) err-locked-period)
        
        ;; Transfer principal + rewards
        (try! (as-contract (stx-transfer? amount tx-sender staker)))
        
        (and (> pending-rewards u0)
            (and (<= pending-rewards (var-get reward-pool))
                (try! (as-contract (stx-transfer? pending-rewards tx-sender staker)))))
        
        ;; Remove stake record
        (map-delete stakes staker)
        
        ;; Update stats
        (let
            (
                (current-stats (get-user-stats staker))
            )
            (map-set user-stats staker 
                (merge current-stats {
                    total-rewards-earned: (+ (get total-rewards-earned current-stats) pending-rewards)
                })
            )
        )
        
        ;; Update global stats
        (var-set total-staked (- (var-get total-staked) amount))
        (var-set staker-count (- (var-get staker-count) u1))
        (and (> pending-rewards u0)
            (var-set reward-pool (- (var-get reward-pool) pending-rewards)))
        
        (ok total-payout)
    )
)

;; Emergency withdraw (forfeit rewards)
(define-public (emergency-withdraw)
    (let
        (
            (staker tx-sender)
            (stake-data (unwrap! (map-get? stakes staker) err-not-staked))
            (amount (get amount stake-data))
        )
        ;; Validations
        (asserts! (var-get emergency-withdraw-enabled) err-paused)
        
        ;; Transfer only principal (no rewards)
        (try! (as-contract (stx-transfer? amount tx-sender staker)))
        
        ;; Remove stake record
        (map-delete stakes staker)
        
        ;; Update global stats
        (var-set total-staked (- (var-get total-staked) amount))
        (var-set staker-count (- (var-get staker-count) u1))
        
        (ok amount)
    )
)

;; Admin Functions

;; Add rewards to pool
(define-public (add-rewards (amount uint))
    (begin
        (asserts! (> amount u0) err-invalid-amount)
        (asserts! (>= (stx-get-balance tx-sender) amount) err-insufficient-balance)
        
        ;; Transfer to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Update reward pool
        (var-set reward-pool (+ (var-get reward-pool) amount))
        
        (ok amount)
    )
)

;; Set base APY
(define-public (set-base-apy (new-apy uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= new-apy u10000) err-invalid-amount) ;; Max 100% APY
        (var-set base-apy new-apy)
        (ok new-apy)
    )
)

;; Set max stakers
(define-public (set-max-stakers (new-max uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (> new-max u0) err-invalid-amount)
        (var-set max-stakers new-max)
        (ok new-max)
    )
)

;; Pause/Unpause contract
(define-public (pause-contract (paused-state bool))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set paused paused-state)
        (ok paused-state)
    )
)

;; Enable/Disable emergency withdraw
(define-public (set-emergency-withdraw (enabled bool))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set emergency-withdraw-enabled enabled)
        (ok enabled)
    )
)

;; Enable/Disable compound feature
(define-public (set-compound-enabled (enabled bool))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set compound-enabled enabled)
        (ok enabled)
    )
)

;; Withdraw excess rewards (owner only)
(define-public (withdraw-excess-rewards (amount uint))
    (let
        (
            (current-pool (var-get reward-pool))
        )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= amount current-pool) err-insufficient-balance)
        
        ;; Transfer to owner
        (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
        
        ;; Update pool
        (var-set reward-pool (- current-pool amount))
        
        (ok amount)
    )
)