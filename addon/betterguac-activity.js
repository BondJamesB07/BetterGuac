/*
 * BetterGuac: Activity page (admins only), at #/activity.
 *
 * Reads api/session/ext/{data source}/audit/... (AuditResource.java):
 * sign-ins, failed sign-ins, two-factor steps, sign-outs, sessions on
 * servers, admin changes to users, servers, groups and permissions, YAML
 * sync applies, and changes to the log's own settings. Filters, search,
 * paging, CSV export of what the filters show, and retention settings.
 */

angular.module('index').config(['$routeProvider', function bgActivityRoute($routeProvider) {

    $routeProvider.when('/activity', {
        title         : 'APP.NAME',
        bodyClassName : 'settings bg-activity-page',
        template      : ''
            + '<div class="settings-view view bg-activity" ng-controller="bgActivityController">'
            +   '<div class="header">'
            +     '<h2>Activity</h2>'
            +     '<div class="user-menu bg-user-menu-replaced"><bg-nav></bg-nav></div>'
            +   '</div>'

            +   '<div class="bg-act-denied" ng-if="act.denied">Only admins can see the activity log.</div>'

            +   '<div ng-if="!act.denied">'
            +   '<bg-help class="bg-help-activity" label="What is this page?">'
            +     '<p><strong>Activity</strong></p>'
            +     '<ul>'
            +       '<li>Everything people did in BetterGuac, newest first: sign-ins and failed sign-ins, two-factor steps, sign-outs, sessions on servers, and admin changes to users, servers, groups and permissions. YAML sync applies show up too.</li>'
            +       '<li>Session start and end come from Guacamole\'s own session history, so sessions from before this page existed are listed too.</li>'
            +       '<li><strong>Export CSV</strong> downloads every row the filters match (up to 50,000). The export itself is logged.</li>'
            +       '<li><strong>Retention</strong> deletes old rows once a day. 0 keeps everything.</li>'
            +     '</ul>'
            +   '</bg-help>'

            +   '<div class="bg-act-chips" role="group" aria-label="Kinds of activity">'
            +     '<button type="button" class="bg-act-chip" ng-class="{ \'bg-on\' : !act.categories.length }" ng-click="allCategories()">All</button>'
            +     '<button type="button" class="bg-act-chip" ng-repeat="c in CATEGORIES" data-cat="{{ c.key }}" '
            +        'ng-class="{ \'bg-on\' : act.categories.indexOf(c.key) >= 0 }" ng-click="toggleCategory(c.key)">{{ c.label }}</button>'
            +   '</div>'

            +   '<form class="bg-act-filters" ng-submit="search()">'
            +     '<label>Search<input type="search" ng-model="act.q" placeholder="Name, server, address, detail" ng-model-options="{ debounce : 350 }" ng-change="search()"></label>'
            +     '<label>User<input type="text" ng-model="act.actor" placeholder="Exact sign-in name" ng-model-options="{ debounce : 350 }" ng-change="search()"></label>'
            +     '<label>Result<select ng-model="act.outcome" ng-change="search()">'
            +       '<option value="">Any</option><option value="success">Succeeded</option>'
            +       '<option value="failure">Failed</option><option value="info">Info</option></select></label>'
            +     '<label>From<input type="date" ng-model="act.from" ng-change="search()"></label>'
            +     '<label>To<input type="date" ng-model="act.to" ng-change="search()"></label>'
            +     '<div class="bg-act-buttons">'
            +       '<button type="button" class="bg-btn bg-act-clear" ng-click="clear()">Clear</button>'
            +       '<button type="button" class="bg-btn bg-act-export" ng-click="exportCsv()" ng-disabled="act.exporting">{{ act.exporting ? \'Exporting...\' : \'Export CSV\' }}</button>'
            +       '<button type="button" class="bg-btn bg-act-settings-btn" ng-click="openSettings()">Retention</button>'
            +     '</div>'
            +   '</form>'

            +   '<div class="bg-act-error" ng-show="act.error">{{ act.error }}</div>'
            +   '<div class="bg-act-summary" ng-show="act.loaded">'
            +     '{{ act.total === 0 ? \'No activity matches.\' : (act.offset + 1) + \'-\' + (act.offset + act.events.length) + \' of \' + act.total }}'
            +   '</div>'

            +   '<div class="bg-act-list" role="table" aria-label="Activity">'
            +     '<div class="bg-act-row bg-act-head" role="row">'
            +       '<span role="columnheader">When</span><span role="columnheader">What</span>'
            +       '<span role="columnheader">Who</span><span role="columnheader">On</span>'
            +       '<span role="columnheader">Detail</span><span role="columnheader">From</span>'
            +     '</div>'
            +     '<div class="bg-act-row" role="row" ng-repeat="e in act.events track by e.id" data-action="{{ e.action }}" '
            +        'ng-class="\'bg-out-\' + e.outcome">'
            +       '<span class="bg-act-when" role="cell" title="{{ e.time | date : \'medium\' }}">{{ when(e.time) }}</span>'
            +       '<span class="bg-act-what" role="cell"><span class="bg-act-tag" data-cat="{{ e.category }}">{{ categoryLabel(e.category) }}</span> {{ actionLabel(e) }}</span>'
            +       '<span class="bg-act-who" role="cell"><a href="" ng-if="e.actor" ng-click="filterActor(e.actor)" title="Show only {{ e.actor }}">{{ e.actor }}</a><span ng-if="!e.actor" class="bg-muted">unknown</span></span>'
            +       '<span class="bg-act-on" role="cell">{{ e.targetName || \'\' }}</span>'
            +       '<span class="bg-act-detail" role="cell">{{ e.detail || \'\' }}<span class="bg-act-src" ng-if="e.source && e.source !== \'web\'"> ({{ e.source }})</span></span>'
            +       '<span class="bg-act-from" role="cell">{{ e.remoteAddr || \'\' }}</span>'
            +     '</div>'
            +   '</div>'

            +   '<div class="bg-act-pager" ng-show="act.total > act.limit">'
            +     '<button type="button" class="bg-btn" ng-click="page(-1)" ng-disabled="act.offset === 0">Newer</button>'
            +     '<button type="button" class="bg-btn" ng-click="page(1)" ng-disabled="act.offset + act.limit >= act.total">Older</button>'
            +   '</div>'

            +   '<div class="bg-modal-backdrop bg-act-modal" ng-if="act.settingsOpen" ng-click="closeSettings($event)">'
            +     '<div class="bg-modal" role="dialog" aria-label="Retention">'
            +       '<h3>Retention</h3>'
            +       '<p class="bg-muted">{{ act.settings.eventCount }} activity rows, oldest {{ act.settings.oldestEvent ? (act.settings.oldestEvent | date : \'mediumDate\') : \'none yet\' }}. {{ act.settings.sessionCount }} sessions in session history.</p>'
            +       '<label>Keep activity for (days, 0 = forever)<input type="number" min="0" max="3650" ng-model="act.edit.retentionDays"></label>'
            +       '<label>Keep session history for (days, 0 = forever)<input type="number" min="0" max="3650" ng-model="act.edit.sessionRetentionDays"></label>'
            +       '<div class="bg-act-error" ng-show="act.settingsError">{{ act.settingsError }}</div>'
            +       '<div class="bg-act-ok" ng-show="act.settingsNote">{{ act.settingsNote }}</div>'
            +       '<div class="bg-modal-actions">'
            +         '<button type="button" class="bg-btn" ng-click="purgeNow()">Delete old rows now</button>'
            +         '<button type="button" class="bg-btn" ng-click="act.settingsOpen = false">Close</button>'
            +         '<button type="button" class="bg-btn bg-btn-primary" ng-click="saveSettings()">Save</button>'
            +       '</div>'
            +     '</div>'
            +   '</div>'
            +   '</div>'
            + '</div>',
        resolve : {
            updateCurrentToken : ['$injector', function ($injector) {
                return $injector.get('authenticationService').updateCurrentToken($injector.get('$location').search());
            }]
        }
    });

}]);

angular.module('index').controller('bgActivityController', ['$scope', '$injector',
        function bgActivityController($scope, $injector) {

    var $http                 = $injector.get('$http');
    var $window               = $injector.get('$window');
    var authenticationService = $injector.get('authenticationService');
    var bgSession             = $injector.get('bgSession');

    $scope.CATEGORIES = [
        { key : 'auth',       label : 'Sign-ins' },
        { key : 'mfa',        label : 'Two-factor' },
        { key : 'session',    label : 'Sessions' },
        { key : 'user',       label : 'Users' },
        { key : 'group',      label : 'Groups' },
        { key : 'server',     label : 'Servers' },
        { key : 'permission', label : 'Permissions' },
        { key : 'sync',       label : 'YAML sync' },
        { key : 'audit',      label : 'Log settings' }
    ];

    var ACTIONS = {
        'auth.login'                   : 'Signed in',
        'auth.failed'                  : 'Sign-in failed',
        'auth.logout'                  : 'Signed out',
        'auth.password_change_required': 'Must change password',
        'mfa.challenge'                : 'Asked for code',
        'mfa.failed'                   : 'Code rejected',
        'mfa.enroll_prompt'            : 'Asked to set up',
        'mfa.reset_self'               : 'Reset own two-factor',
        'mfa.reset_user'               : 'Admin reset two-factor',
        'session.start'                : 'Session started',
        'session.end'                  : 'Session ended',
        'session.killed'               : 'Session ended by admin',
        'user.created'                 : 'User added',
        'user.updated'                 : 'User changed',
        'user.deleted'                 : 'User deleted',
        'user.role_changed'            : 'Role changed',
        'group.created'                : 'Group added',
        'group.updated'                : 'Group changed',
        'group.deleted'                : 'Group deleted',
        'group.member_added'           : 'Added to group',
        'group.member_removed'         : 'Removed from group',
        'group.role_changed'           : 'Group role changed',
        'server.created'               : 'Server added',
        'server.updated'               : 'Server changed',
        'server.deleted'               : 'Server deleted',
        'folder.created'               : 'Folder added',
        'folder.updated'               : 'Folder changed',
        'folder.deleted'               : 'Folder deleted',
        'permission.granted'           : 'Access granted',
        'permission.revoked'           : 'Access removed',
        'sync.applied'                 : 'YAML plan applied',
        'audit.exported'               : 'Log exported',
        'audit.settings_changed'       : 'Retention changed',
        'audit.purged'                 : 'Old rows deleted'
    };

    var act = $scope.act = {
        categories : [], q : '', actor : '', outcome : '', from : null, to : null,
        offset : 0, limit : 100, total : 0, events : [], loaded : false, error : null
    };

    var ds = function ds() { return bgSession.dataSource() || authenticationService.getDataSource(); };
    var base = function base() { return 'api/session/ext/' + encodeURIComponent(ds()) + '/audit/'; };
    var token = function token() { return { 'Guacamole-Token' : authenticationService.getCurrentToken() }; };

    var day = function day(d) {
        if (!d) return undefined;
        var p = function (n) { return (n < 10 ? '0' : '') + n; };
        return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
    };

    var params = function params() {
        return {
            category : act.categories.length ? act.categories.join(',') : undefined,
            q        : act.q || undefined,
            actor    : act.actor || undefined,
            outcome  : act.outcome || undefined,
            from     : day(act.from),
            to       : day(act.to)
        };
    };

    var errorOf = function errorOf(r, fallback) {
        return (r && r.data && r.data.message) || fallback;
    };

    var load = function load() {
        var p = params();
        p.limit = act.limit;
        p.offset = act.offset;
        act.error = null;
        $http({ method : 'GET', url : base() + 'events', params : p, headers : token(), cache : false })
            .then(function (r) {
                act.events = r.data.events || [];
                act.total = r.data.total || 0;
                act.loaded = true;
            }, function (r) {
                if (r.status === 403) act.denied = true;
                act.error = errorOf(r, 'Couldn\'t load the activity log.');
            });
    };

    $scope.search = function search() { act.offset = 0; load(); };
    $scope.page = function page(dir) {
        act.offset = Math.max(0, act.offset + dir * act.limit);
        load();
    };
    $scope.allCategories = function allCategories() { act.categories = []; $scope.search(); };
    $scope.toggleCategory = function toggleCategory(key) {
        var i = act.categories.indexOf(key);
        if (i >= 0) act.categories.splice(i, 1); else act.categories.push(key);
        $scope.search();
    };
    $scope.filterActor = function filterActor(name) { act.actor = name; $scope.search(); };
    $scope.clear = function clear() {
        act.categories = []; act.q = ''; act.actor = ''; act.outcome = ''; act.from = null; act.to = null;
        $scope.search();
    };

    $scope.categoryLabel = function categoryLabel(key) {
        for (var i = 0; i < $scope.CATEGORIES.length; i++)
            if ($scope.CATEGORIES[i].key === key) return $scope.CATEGORIES[i].label;
        return key;
    };
    $scope.actionLabel = function actionLabel(e) {
        if (ACTIONS[e.action]) return ACTIONS[e.action];
        if (/^sync\./.test(e.action)) return 'YAML: ' + e.action.substring(5);
        return e.action;
    };

    // "3 min ago" today, the date and time before that
    $scope.when = function when(t) {
        var d = new Date(t), now = new Date(), s = (now - d) / 1000;
        if (s < 60) return 'just now';
        if (s < 3600) return Math.floor(s / 60) + ' min ago';
        if (d.toDateString() === now.toDateString())
            return d.toLocaleTimeString([], { hour : 'numeric', minute : '2-digit' });
        return d.toLocaleDateString([], { month : 'short', day : 'numeric', year : d.getFullYear() === now.getFullYear() ? undefined : 'numeric' })
             + ', ' + d.toLocaleTimeString([], { hour : 'numeric', minute : '2-digit' });
    };

    $scope.exportCsv = function exportCsv() {
        act.exporting = true;
        $http({ method : 'GET', url : base() + 'export', params : params(), headers : token(),
                responseType : 'blob', cache : false })
            .then(function (r) {
                var name = 'betterguac-activity.csv';
                var cd = r.headers('Content-Disposition') || '';
                var m = /filename="([^"]+)"/.exec(cd);
                if (m) name = m[1];
                var url = $window.URL.createObjectURL(r.data);
                var a = $window.document.createElement('a');
                a.href = url; a.download = name;
                $window.document.body.appendChild(a); a.click(); a.remove();
                setTimeout(function () { $window.URL.revokeObjectURL(url); }, 2000);
            }, function () {
                act.error = 'The export failed.';
            })['finally'](function () { act.exporting = false; });
    };

    $scope.openSettings = function openSettings() {
        act.settingsError = null; act.settingsNote = null;
        $http({ method : 'GET', url : base() + 'settings', headers : token(), cache : false })
            .then(function (r) {
                act.settings = r.data;
                act.edit = { retentionDays : r.data.retentionDays, sessionRetentionDays : r.data.sessionRetentionDays };
                act.settingsOpen = true;
            }, function (r) { act.error = errorOf(r, 'Couldn\'t load the retention settings.'); });
    };
    $scope.closeSettings = function closeSettings(ev) {
        if (ev && ev.target === ev.currentTarget) act.settingsOpen = false;
    };
    $scope.saveSettings = function saveSettings() {
        act.settingsError = null; act.settingsNote = null;
        $http({ method : 'PUT', url : base() + 'settings', headers : token(), data : act.edit })
            .then(function (r) {
                act.settings = r.data;
                act.settingsNote = 'Saved.';
                load();
            }, function (r) { act.settingsError = errorOf(r, 'Couldn\'t save.'); });
    };
    $scope.purgeNow = function purgeNow() {
        act.settingsError = null; act.settingsNote = null;
        $http({ method : 'POST', url : base() + 'purge', headers : token() })
            .then(function (r) {
                act.settingsNote = 'Deleted ' + r.data.activityDeleted + ' activity rows and '
                    + r.data.sessionsDeleted + ' session history rows.';
                load();
            }, function (r) { act.settingsError = errorOf(r, 'Couldn\'t delete old rows.'); });
    };

    load();
}]);
