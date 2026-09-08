'use strict';
(function() {
  var form = document.querySelector('form[name="cbi"]');
  if (!form) return;
  form.id = 'stargate-cbi-form';
  function syncSurface() {
    var section=form.querySelector('.cbi-section');
    while(section) {
      var color=getComputedStyle(section).backgroundColor;
      if(color!=='rgba(0, 0, 0, 0)' && color!=='transparent') { form.style.setProperty('--sg-surface',color); break; }
      section=section.parentElement;
    }
  }
  syncSurface();
  window.addEventListener('load',syncSurface);
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change',syncSurface);
  var feedback = document.getElementById('stargate-feedback');
  function message(text) { feedback.textContent = text; feedback.scrollIntoView({block:'nearest'}); }
  document.addEventListener('click', function(ev) {
    var button = ev.target.closest('[data-stargate-action]');
    if (!button) return;
    ev.preventDefault();
    if (button.dataset.confirm && !window.confirm(button.dataset.confirm)) return;
    var field = button.dataset.field;
    var input = form.querySelector('[name="' + field + '"]');
    if (!input) { input = document.createElement('input'); input.type = 'hidden'; input.name = field; form.appendChild(input); }
    input.value = button.dataset.stargateAction;
    if (button.dataset.node) {
      var id = document.createElement('input'); id.type='hidden'; id.name='node_id'; id.value=button.dataset.node; form.appendChild(id);
    }
    form.requestSubmit();
  });
  document.querySelectorAll('[data-upload-url]').forEach(function(button) {
    button.addEventListener('click', async function() {
      var file = document.getElementById(button.dataset.file).files[0];
      if (!file) { message('请先选择文件。'); return; }
      if (!window.confirm(button.dataset.confirm)) return;
      var data = new FormData();
      data.append('token',form.querySelector('[name="token"]').value);
      data.append(button.dataset.uploadAction,'1');
      data.append(button.dataset.fileField,file);
      button.disabled=true;
      message('正在处理，请稍候...');
      try {
        var response=await fetch(button.dataset.uploadUrl,{method:'POST',body:data});
        if (!response.ok) throw new Error('HTTP '+response.status);
        var result=await response.json();
        if (!result.ok) throw new Error(result.output || '操作失败');
        message(result.output || '操作完成');
      } catch(e) { message('操作失败：'+e.message); }
      finally { button.disabled=false; }
    });
  });
  document.querySelectorAll('.stargate-node-field').forEach(function(field,index) {
    var label=field.querySelector('label'), input=field.querySelector('input,textarea');
    if (!label || !input) return;
    if (!input.id) input.id='stargate-field-'+index;
    label.htmlFor=input.id;
    input.autocomplete='off';
    if (input.name.endsWith('_port')) { input.type='number'; input.min='1'; input.max='65535'; }
  });
  document.querySelectorAll('.stargate-node-dialog').forEach(function(dialog) {
    dialog.setAttribute('role','dialog'); dialog.setAttribute('aria-modal','true');
    dialog.setAttribute('aria-label',dialog.querySelector('.stargate-node-dialog-title').textContent);
    dialog.querySelector('.stargate-node-x').setAttribute('aria-label','关闭');
    dialog.addEventListener('keydown',function(ev) {
      if(ev.key!=='Tab') return;
      var fields=Array.from(dialog.querySelectorAll('button,input,textarea')).filter(function(el){return !el.disabled && el.offsetParent;});
      var first=fields[0],last=fields[fields.length-1];
      if(ev.shiftKey && document.activeElement===first){ev.preventDefault();last.focus();}
      else if(!ev.shiftKey && document.activeElement===last){ev.preventDefault();first.focus();}
    });
  });
  document.querySelectorAll('.stargate-node-modal').forEach(function(modal) {
    modal.querySelectorAll('input,textarea,button').forEach(function(input) { input.setAttribute('form',form.id); });
    document.body.appendChild(modal);
  });
  var previousFocus;
  var openModal=window.stargateOpenNodeModal, closeModal=window.stargateCloseNodeModal;
  if (openModal) window.stargateOpenNodeModal=function(id) { previousFocus=document.activeElement; openModal(id); };
  if (closeModal) window.stargateCloseNodeModal=function(el) { closeModal(el); if(previousFocus)previousFocus.focus(); };
})();
