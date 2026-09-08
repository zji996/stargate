'use strict';
(function() {
  var root=document.querySelector('.sg-overview');
  if(!root) return;
  var map=root.closest('#cbi-stargate');
  function linkLabels() {
    map.querySelectorAll('.cbi-value').forEach(function(row) {
      var title=row.querySelector('.cbi-value-title');
      var input=row.querySelector('input[type=checkbox]');
      if(title && input && input.id) title.htmlFor=input.id;
    });
    sync();
  }
  linkLabels();
  new MutationObserver(linkLabels).observe(map,{subtree:true,childList:true,attributes:true,attributeFilter:['id']});
  root.querySelectorAll('.sg-probe').forEach(function(button) {
    button.addEventListener('click',async function() {
      button.disabled=true;
      button.removeAttribute('data-result');
      var label=button.querySelector('.sg-probe-result');
      label.textContent=button.dataset.checking;
      var controller=new AbortController();
      var timer=setTimeout(function(){controller.abort();},15000);
      try {
        var response=await fetch(root.dataset.probeUrl+'?target='+button.dataset.target,{signal:controller.signal});
        if(!response.ok) throw new Error('probe failed');
        var result=await response.json();
        button.dataset.result=result.ok?'ok':'failed';
        label.textContent=result.ok?result.use_time+' ms':button.dataset.failed;
      } catch(e) { button.dataset.result='failed'; label.textContent=button.dataset.failed; }
      finally { clearTimeout(timer); button.disabled=false; }
    });
  });
  function sync() {
    var local=map.querySelector('[name="cbid.stargate.global.enabled"][type=checkbox]');
    var transparent=map.querySelector('[name="cbid.stargate.inbound.transparent_proxy"][type=checkbox]');
    if(!local || !transparent) return;
    if(!local.checked && transparent.checked) {
      transparent.checked=false;
      transparent.dispatchEvent(new Event('change',{bubbles:true}));
    }
    transparent.disabled=!local.checked;
  }
  map.addEventListener('change',function(ev) {
    if(ev.target.name==='cbid.stargate.global.enabled') sync();
  });
  window.addEventListener('load',sync);
  sync();
})();
