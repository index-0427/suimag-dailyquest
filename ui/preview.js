'use strict';
// Development only: not listed in fxmanifest and never loaded by FiveM.
const frame = document.querySelector('iframe');
let board;
function resetPreview() {
  board = {
    ok: true, preferences: {crime:true,employment:false}, rerolls:{daily:1,weekly:1},
    dailyReset:'11/07 05:00 (UTC+09:00)', weeklyReset:'11/09 05:00 (UTC+09:00)',
    quests:[
      {id:'visit',period:'daily',title:'今日の街歩き',description:'キャラクターで街に参加する。',value:1,target:1,unit:'日',scale:1,status:'active',reward:'銀行 $150,000'},
      {id:'time',period:'daily',title:'街で過ごす30分',description:'今日、合計30分間接続する（離席時間を含む）。',value:1080,target:1800,unit:'分',scale:60,status:'active',canReroll:true,reward:'銀行 $150,000'},
      {id:'food',period:'daily',title:'食事を忘れずに',description:'水またはバーガーを合計3回使用する。',value:1,target:3,unit:'回',scale:1,status:'active',canReroll:true,reward:'銀行 $150,000'},
      {id:'week',period:'weekly',title:'今週の常連',description:'今週、異なる3日間に街に参加する。',value:2,target:3,unit:'日',scale:1,status:'active',canReroll:true,reward:'銀行 $500,000'},
      {id:'week-time',period:'weekly',title:'街と過ごす一週間',description:'今週、合計3時間接続する。',value:10800,target:10800,unit:'時間',scale:3600,status:'pending',reward:'銀行 $500,000'}
    ], dailyBonus:{completed:1,total:3,status:'active',canClaim:false,reward:'銀行 $200,000'}
  };
  send('gui',{visible:true,data:board,selected:'daily'});
  send('countdown',{visible:true,remaining:18327,resetLabel:board.dailyReset});
}
function send(type, data) { frame.contentWindow.postMessage({action:'suimag-dailyquest:'+type,...data},location.origin); }
frame.onload = () => {
  const win = frame.contentWindow;
  win.GetParentResourceName = () => 'suimag-preview';
  win.fetch = async (_, options) => {
    const data = JSON.parse(options.body);
    if (data.action === 'close') { send('gui',{visible:false});send('countdown',{visible:false}); }
    else if (data.action === 'claim') {
      const quest = board.quests.find(q => q.id === data.id);
      if (quest && quest.value >= quest.target && quest.status === 'active') quest.status = 'claimed';
      send('gui',{visible:true,data:board});
    } else if (data.action === 'refresh') send('gui',{visible:true,data:board});
    else if (data.action === 'preferences' || data.action === 'reroll') {
      win.document.getElementById('gui-error').textContent = 'プレビューでは表示のみです。ゲーム内では設定・交換の確認ダイアログが開きます。';
    }
    return {ok:true};
  };
  resetPreview();
};
document.getElementById('reopen').onclick = resetPreview;
