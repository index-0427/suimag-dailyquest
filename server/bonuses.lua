local S = DQStore

local assignedCount = [[(SELECT COUNT(*) FROM suimag_dailyquest_assignments a
    WHERE a.citizenid=b.citizenid AND a.period_kind='daily' AND a.period_start=b.period_start AND a.active=1)]]
local completedCount = [[(SELECT COUNT(*) FROM suimag_dailyquest_assignments a
    JOIN suimag_dailyquest_progress p ON p.citizenid=a.citizenid AND p.quest_id=a.quest_id AND p.period_start=a.period_start
    WHERE a.citizenid=b.citizenid AND a.period_kind='daily' AND a.period_start=b.period_start
    AND a.active=1 AND p.progress>=p.target)]]

S.bonusCounts={assigned=assignedCount,completed=completedCount}

S.sql.ensureBonus = [[INSERT INTO suimag_dailyquest_bonuses
    (citizenid, period_start, ends_at, required_count, reward_type, reward_amount)
    SELECT citizenid, period_start, ends_at, ?, ?, ? FROM suimag_dailyquest_boards b
    WHERE citizenid=? AND period_kind='daily' AND period_start<=? AND ends_at>?
    AND ]] .. assignedCount .. [[ = ? ON DUPLICATE KEY UPDATE id=id]]
S.sql.syncBonusReward = [[UPDATE suimag_dailyquest_bonuses SET reward_type=?, reward_amount=?
    WHERE citizenid=? AND period_start<=? AND ends_at>? AND status='active']]
S.sql.syncQuestRewards = [[UPDATE suimag_dailyquest_progress p SET reward_type=?, reward_amount=?, reward_coin='', reward_coin_amount=0
    WHERE citizenid=? AND period_kind=? AND period_start<=? AND ends_at>? AND status='active'
    AND EXISTS (SELECT 1 FROM suimag_dailyquest_assignments a WHERE a.citizenid=p.citizenid
        AND a.quest_id=p.quest_id AND a.period_start=p.period_start AND a.active=1)]]
S.sql.syncQuestCoin = [[UPDATE suimag_dailyquest_progress p SET reward_coin=?, reward_coin_amount=?
    WHERE citizenid=? AND quest_id=? AND period_start<=? AND ends_at>? AND status='active'
    AND EXISTS (SELECT 1 FROM suimag_dailyquest_assignments a WHERE a.citizenid=p.citizenid
        AND a.quest_id=p.quest_id AND a.period_start=p.period_start AND a.active=1)]]
S.sql.bonusState = [[SELECT b.*, ]] .. assignedCount .. [[ AS assigned_count, ]]
    .. completedCount .. [[ AS completed_count FROM suimag_dailyquest_bonuses b WHERE citizenid=? AND period_start=?]]
S.sql.reserveBonus = [[UPDATE suimag_dailyquest_bonuses b SET status='pending', attempted_at=?
    WHERE id=? AND citizenid=? AND status='active' AND ends_at>? AND required_count>0
    AND required_count=]] .. assignedCount .. [[ AND required_count=]] .. completedCount
S.sql.releaseBonus = [[UPDATE suimag_dailyquest_bonuses SET status='active', attempted_at=NULL WHERE id=? AND status='pending']]
S.sql.finishBonus = [[UPDATE suimag_dailyquest_bonuses SET status='claimed', claimed_at=? WHERE id=? AND status='pending']]
S.sql.pending = [[SELECT 'quest' AS claim_kind, id, citizenid, quest_id, period_start, attempted_at, reward_type, reward_amount, reward_coin, reward_coin_amount
    FROM suimag_dailyquest_progress WHERE status='pending'
    UNION ALL
    SELECT 'daily_bonus' AS claim_kind, id, citizenid, 'daily_complete_bonus' AS quest_id, period_start, attempted_at, reward_type, reward_amount, '' AS reward_coin, 0 AS reward_coin_amount
    FROM suimag_dailyquest_bonuses WHERE status='pending'
    ORDER BY attempted_at LIMIT 50]]

-- Join the existing open transaction. Paid and uncertain claims keep the original amount.
function S.rewardQueries(citizenid, now)
    local bonus=DQ.reward('dailyComplete')
    local queries={
        {query=S.sql.ensureBonus,values={Config.Draw.daily,bonus.type,bonus.amount,citizenid,now,now,Config.Draw.daily}},
        {query=S.sql.syncBonusReward,values={bonus.type,bonus.amount,citizenid,now,now}},
    }
    for _,kind in ipairs({'daily','weekly'}) do
        local reward=DQ.reward(kind)
        queries[#queries+1]={query=S.sql.syncQuestRewards,values={reward.type,reward.amount,citizenid,kind,now,now}}
    end
    for _,quest in ipairs(Config.Quests) do
        local coin,amount=DQ.coins(quest)
        if amount>0 then
            queries[#queries+1]={query=S.sql.syncQuestCoin,values={coin,amount,citizenid,quest.id,now,now}}
        end
    end
    return queries
end

function S.bonusState(citizenid, periodStart)
    return MySQL.single.await(S.sql.bonusState,{citizenid,periodStart})
end
function S.reserveBonus(citizenid,id,now)
    return MySQL.update.await(S.sql.reserveBonus,{now,id,citizenid,now})==1
end
function S.releaseBonus(id)
    assert(MySQL.update.await(S.sql.releaseBonus,{id})==1,'Could not release daily bonus')
end
function S.finishBonus(id,now)
    assert(MySQL.update.await(S.sql.finishBonus,{now,id})==1,'Could not finalize daily bonus')
end
