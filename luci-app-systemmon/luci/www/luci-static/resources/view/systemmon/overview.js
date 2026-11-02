'require view';

return view.extend({
	load: function () {
		return Promise.resolve();
	},

	render: function () {
		var url = window.location.protocol + '//' + window.location.hostname + ':7752/';

		return E('iframe', {
			'src': url,
			'title': 'systemmon',
			'style': 'width:100%;height:calc(100vh - 150px);min-height:560px;border:0;border-radius:8px;background:#070d18'
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
