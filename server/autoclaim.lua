DQAuto = {}

-- Called while the existing character lock is held. Only the server invokes this path.
function DQAuto.collect(source,session,now,current,deliver)
    local summary={quests=0,bonuses=0,bank=0,cash=0,pending=0,coins={}}
    local candidates=DQStore.expiredDaily(session.citizenid,now)
    for _,row in ipairs(candidates) do
        if not current(source,session) then break end
        assert(row.citizenid==session.citizenid and row.period_kind=='daily','Invalid automatic claim owner or period')
        assert(row.claim_kind=='quest' or row.claim_kind=='daily_bonus','Invalid automatic claim kind')
        assert(DQ.integer(row.reward_amount,1,10000000),'Invalid automatic reward amount')
        assert(row.reward_type=='bank' or row.reward_type=='cash','Invalid automatic reward type')
        if current(source,session) and DQStore.reserveExpired(session.citizenid,row,os.time()) then
            local result=deliver(source,session,row,row.claim_kind,true)
            if result.ok then
                local field=row.claim_kind=='daily_bonus' and 'bonuses' or 'quests'
                summary[field]=summary[field]+1
                summary[row.reward_type]=summary[row.reward_type]+row.reward_amount
                if result.coinAmount and result.coinAmount>0 then
                    summary.coins[result.coin]=(summary.coins[result.coin] or 0)+result.coinAmount
                end
            elseif result.error=='pending' then summary.pending=summary.pending+1 end
        end
    end
    return summary
end
