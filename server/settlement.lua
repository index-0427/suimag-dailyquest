local S=DQStore
local counts=S.bonusCounts

S.sql.initSettlement = [[INSERT INTO suimag_dailyquest_automation (id,daily_after) VALUES (1,?)
    ON DUPLICATE KEY UPDATE daily_after=daily_after]]
S.sql.settlementStart = [[SELECT daily_after FROM suimag_dailyquest_automation WHERE id=1]]
S.sql.expiredDaily = [[SELECT 'quest' AS claim_kind, id, citizenid, quest_id, period_kind, period_start, ends_at,
    reward_type, reward_amount, reward_coin, reward_coin_amount FROM suimag_dailyquest_progress p
    WHERE citizenid=? AND period_kind='daily' AND status='active' AND progress>=target AND ends_at<=? AND ends_at>=?
    AND EXISTS (SELECT 1 FROM suimag_dailyquest_assignments a WHERE a.citizenid=p.citizenid
        AND a.quest_id=p.quest_id AND a.period_start=p.period_start AND a.period_kind='daily' AND a.active=1)
    UNION ALL
    SELECT 'daily_bonus' AS claim_kind, id, citizenid, 'daily_complete_bonus' AS quest_id, 'daily' AS period_kind,
    period_start, ends_at, reward_type, reward_amount, '' AS reward_coin, 0 AS reward_coin_amount FROM suimag_dailyquest_bonuses b
    WHERE citizenid=? AND status='active' AND ends_at<=? AND ends_at>=? AND required_count>0
    AND required_count=]] .. counts.assigned .. [[ AND required_count=]] .. counts.completed ..
    [[ ORDER BY ends_at, claim_kind, id LIMIT ?]]
S.sql.reserveExpiredDaily = [[UPDATE suimag_dailyquest_progress p SET status='pending', attempted_at=?
    WHERE id=? AND citizenid=? AND period_kind='daily' AND status='active' AND progress>=target AND ends_at<=? AND ends_at>=?
    AND EXISTS (SELECT 1 FROM suimag_dailyquest_assignments a WHERE a.citizenid=p.citizenid
        AND a.quest_id=p.quest_id AND a.period_start=p.period_start AND a.period_kind='daily' AND a.active=1)]]
S.sql.reserveExpiredBonus = [[UPDATE suimag_dailyquest_bonuses b SET status='pending', attempted_at=?
    WHERE id=? AND citizenid=? AND status='active' AND ends_at<=? AND ends_at>=? AND required_count>0
    AND required_count=]] .. counts.assigned .. [[ AND required_count=]] .. counts.completed

function S.initSettlement()
    -- First installation only. Do not resurrect rewards that expired under an earlier version.
    local firstReset=DQ.period('daily',os.time(),Config.Reset).finish
    MySQL.update.await(S.sql.initSettlement,{firstReset})
    S.settlementAfter=tonumber(MySQL.scalar.await(S.sql.settlementStart))
    assert(DQ.integer(S.settlementAfter,1,4102444800),'Invalid automatic settlement start')
end
function S.expiredDaily(citizenid,now)
    return MySQL.query.await(S.sql.expiredDaily,{
        citizenid,now,S.settlementAfter,citizenid,now,S.settlementAfter,Config.AutoClaim.batchSize,
    })
end
function S.reserveExpired(citizenid,row,now)
    local sql=row.claim_kind=='daily_bonus' and S.sql.reserveExpiredBonus or S.sql.reserveExpiredDaily
    return MySQL.update.await(sql,{now,row.id,citizenid,now,S.settlementAfter})==1
end
