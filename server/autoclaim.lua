DQAuto = {}

-- Called while the existing character lock is held. Only the server invokes this path.
function DQAuto.collect(source,session,now,current,deliver)
    local summary={quests=0,bonuses=0,bank=0,cash=0,pending=0}
    local candidates=DQStore.expiredDaily(session.citizenid,now)
    for _,row in ipairs(candidates) do
        if not current(source,session) then break end
        assert(row.citizenid==session.citizenid and row.period_kind=='daily','Invalid automatic claim owner or period')
        assert(row.claim_kind=='quest' or row.claim_kind=='daily_bonus','Invalid automatic claim kind')
        assert(DQ.integer(row.reward_amount,1,10000000),'Invalid automatic reward amount')
        local canDeliver=true
        if row.reward_type=='item' then
            assert(row.claim_kind=='quest' and DQ.identifier(row.reward_name),'Invalid historical item reward')
            canDeliver=exports.ox_inventory:Items(row.reward_name)~=nil
                and exports.ox_inventory:CanCarryItem(source,row.reward_name,row.reward_amount)
        else
            assert(row.reward_type=='bank' or row.reward_type=='cash','Invalid automatic reward type')
        end
        if canDeliver and current(source,session) and DQStore.reserveExpired(session.citizenid,row,os.time()) then
            local result=deliver(source,session,row,row.claim_kind,true)
            if result.ok then
                local field=row.claim_kind=='daily_bonus' and 'bonuses' or 'quests'
                summary[field]=summary[field]+1
                if row.reward_type=='bank' or row.reward_type=='cash' then
                    summary[row.reward_type]=summary[row.reward_type]+row.reward_amount
                end
            elseif result.error=='pending' then summary.pending=summary.pending+1 end
        end
    end
    return summary
end
