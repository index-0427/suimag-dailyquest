'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { formatRemaining, remainingAt } = require('../ui/countdown.js');
for (const [value, expected] of [[86400,'24:00:00'],[3661,'01:01:01'],[60,'00:01:00'],[0.1,'00:00:01'],[-1,'00:00:00'],[NaN,'00:00:00']]) {
  assert.equal(formatRemaining(value),expected);
}
assert.equal(remainingAt(60,1000,61000),0);
assert.equal(remainingAt(60,1000,31000),30);
assert.equal(remainingAt(60,1000,500),60);
let now=1000, listener, tick;
const elements={
  'daily-countdown':{hidden:true,dataset:{}},
  'reset-label':{textContent:''},
  remaining:{textContent:''},
};
vm.runInNewContext(fs.readFileSync('ui/countdown.js','utf8'),{
  window:{addEventListener:(name,fn)=>{assert.equal(name,'message');listener=fn;}},
  document:{getElementById:id=>elements[id]},
  performance:{now:()=>now},
  setInterval:(fn,ms)=>{assert.equal(ms,250);tick=fn;},
});
listener({data:{action:'unrelated',visible:true,remaining:60,resetLabel:'ignored'}});
assert.equal(elements['daily-countdown'].hidden,true);
listener({data:{action:'suimag-dailyquest:countdown',visible:true,remaining:61,resetLabel:'11/05 05:00 (UTC+09:00)'}});
assert.equal(elements['daily-countdown'].hidden,false);
assert.equal(elements.remaining.textContent,'00:01:01');
now+=1000;tick();assert.equal(elements.remaining.textContent,'00:01:00');
now+=60000;tick();assert.equal(elements.remaining.textContent,'更新中…');
assert.equal(elements['daily-countdown'].dataset.expired,'true');
listener({data:{action:'suimag-dailyquest:countdown',visible:false}});
assert.equal(elements['daily-countdown'].hidden,true);
listener({data:{action:'suimag-dailyquest:countdown',visible:true,remaining:Infinity,resetLabel:'bad'}});
assert.equal(elements['daily-countdown'].hidden,true);
listener({data:{action:'suimag-dailyquest:countdown',visible:true,remaining:120,resetLabel:'<img src=x>'}});
assert.equal(elements['reset-label'].textContent,'次回 <img src=x>');
console.log('countdown: formatting, monotonic timing, lifecycle and message validation passed');
