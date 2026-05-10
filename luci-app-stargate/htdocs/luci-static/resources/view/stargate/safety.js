'use strict';
'require view';
'require form';
'require fs';
'require ui';

return view.extend({
  render: function() {
    var m = new form.Map('stargate', _('Safety'));

    var s = m.section(form.NamedSection, 'safety', 'safety', _('System changes'));
    s.anonymous = true;

    var backup = s.option(form.Flag, 'backup_on_apply', _('Backup before apply'));
    backup.default = '1';
    backup.rmempty = false;

    var tp = s.option(form.Flag, 'transparent_proxy', _('Transparent proxy'));
    tp.default = '0';
    tp.rmempty = false;

    var fw = s.option(form.Flag, 'manage_firewall', _('Manage firewall'));
    fw.default = '0';
    fw.rmempty = false;

    var dnsmasq = s.option(form.Flag, 'manage_dnsmasq', _('Manage dnsmasq'));
    dnsmasq.default = '0';
    dnsmasq.rmempty = false;

    var diag = s.option(form.DummyValue, '_diagnostics', _('Diagnostics'));
    diag.rawhtml = true;
    diag.cfgvalue = function() {
      return E('button', {
        'class': 'btn cbi-button cbi-button-neutral',
        'click': ui.createHandlerFn(this, function() {
          return fs.exec('/usr/share/stargate/stargate.sh', [ 'logs' ])
            .then(function(res) {
              ui.showModal(_('Recent logs'), [
                E('pre', { 'style': 'white-space: pre-wrap' }, res.stdout || _('No logs'))
              ]);
            })
            .catch(function(err) { ui.addNotification(null, E('p', {}, err.message), 'danger'); });
        })
      }, [ _('Show logs') ]);
    };

    return m.render();
  }
});
