'require view';

return view.extend({
	load: function () {
		return Promise.resolve();
	},

	render: function () {
		var url = window.location.protocol + '//' + window.location.hostname + ':7752/';

		var bar = E('div', { 'class': 'cbi-page-actions', 'style': 'margin-bottom:8px;display:flex;gap:10px;align-items:center' }, [
			E('a', {
				'class': 'btn cbi-button cbi-button-apply',
				'href': url,
				'target': '_blank',
				'rel': 'noopener'
			}, [ _('在新窗口打开') ]),
			E('span', { 'class': 'cbi-value-description' }, [
				_('监控服务默认监听 7752 端口。若下方空白，请确认 systemmon 服务已启动，或点击左侧按钮新窗口打开。')
			])
		]);

		var frame = E('iframe', {
			'src': url,
			'title': 'systemmon',
			'style': 'width:100%;height:calc(100vh - 190px);min-height:520px;border:0;border-radius:8px;background:#070d18'
		});

		return E('div', {}, [ bar, frame ]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
