/*
 * BetterGuac UI for Guacamole 1.6.0.
 *
 * Front end for: the compact server list, the midnight-blue login, the
 * Admin / User role model, user management, server management, the server
 * edit button, the profile + MFA preferences page and the home greeting.
 *
 * Everything here goes through Guacamole's own REST API and permission
 * model. The only server-side piece is the small profile decorator in the
 * same jar (com.betterguac.profile), which declares the profile fields and
 * validates them; the browser-side checks below are convenience only.
 */

(function () {

'use strict';

/* ---------------------------------------------------------------------
 * Home page while it waits for the server list.
 *
 * The upstream home view has its own loading state (.home-view.loading and
 * the grey spinning cog), but the view is not even in the DOM until the route
 * resolves, and the route itself waits for the connection tree and the user's
 * permissions. So the cog is never seen on the way in; the page just sits
 * empty until the list is ready. BetterGuac shows the avocado for that whole
 * window: a plain element with no Angular bindings (the view is compiled once
 * at boot, so anything added later would never be compiled) is added to the
 * body on load, and removed as soon as the home view arrives or another page
 * (login, settings, ...) comes up instead. On a fresh visit (no session yet)
 * the login page is up, so the avocado is not shown.
 * ------------------------------------------------------------------- */

var AVOCADO_SVG = '<svg class="bg-avocado" viewBox="0 0 40 60" width="60" height="90" aria-hidden="true" focusable="false">'
    + '<path class="bg-avocado-skin" d="M20 2C31 2 39 15 39 33C39 51 31 58 20 58C9 58 1 51 1 33C1 15 9 2 20 2Z"/>'
    + '<path class="bg-avocado-flesh" d="M20 8C29.2 8 35.5 19.2 35.5 33.5C35.5 47.5 29.2 53.5 20 53.5C10.8 53.5 4.5 47.5 4.5 33.5C4.5 19.2 10.8 8 20 8Z"/>'
    + '<circle class="bg-avocado-pit" cx="20" cy="35" r="9"/>'
    + '</svg>';

var startHomeLoadingState = function startHomeLoadingState() {
    var CLASS = 'bg-loading';

    var el = document.createElement('div');
    el.className = CLASS;
    el.setAttribute('role', 'status');
    el.setAttribute('aria-label', 'Loading your servers');
    // the status text is present for assistive tech, not painted; the
    // BETTERGUAC.TEXT_LOADING_SERVERS translation is the same words
    el.innerHTML = '<span class="bg-loading-text">Loading your servers</span>' + AVOCADO_SVG;
    document.body.insertBefore(el, document.body.firstChild);

    // The view arrived, or another page took over (login, settings, client).
    new MutationObserver(function onView() {
        if (!document.querySelector('.' + CLASS))
            return;
        if (document.querySelector('.home-view')
                || document.querySelector('.login-ui')
                || document.querySelector('#content > *'))
            el.parentNode.removeChild(el);
    }).observe(document.body, { childList : true, subtree : true });
};

if (document.body)
    startHomeLoadingState();
else
    document.addEventListener('DOMContentLoaded', startHomeLoadingState);

/* ---------------------------------------------------------------------
 * Role model
 *
 * Admin = the ADMINISTER system permission (plus the create permissions,
 *         which is exactly what the YAML sync grants for "admin: true").
 * User  = none of those: sees only the servers assigned to them (READ
 *         permission) and their own Preferences page.
 * ------------------------------------------------------------------- */

var ADMIN_PERMISSIONS = [
    'ADMINISTER',
    'CREATE_USER',
    'CREATE_USER_GROUP',
    'CREATE_CONNECTION',
    'CREATE_CONNECTION_GROUP',
    'CREATE_SHARING_PROFILE'
];

// Management system permissions that make an account more than a plain User
var MANAGEMENT_PERMISSIONS = ADMIN_PERMISSIONS.concat(['AUDIT']);

var EMAIL_PATTERN = /^[a-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/;

var MAX_NAME_LENGTH   = 64;
var MAX_AVATAR_LENGTH = 4096;

var isEmail = function isEmail(value) {
    return typeof value === 'string' && value.length <= 128 && EMAIL_PATTERN.test(value);
};

/**
 * Returns 'admin', 'user' or 'custom' for a PermissionSet (or the
 * systemPermissions array inside one).
 */
var roleOf = function roleOf(systemPermissions) {
    var perms = systemPermissions || [];
    if (perms.indexOf('ADMINISTER') !== -1)
        return 'admin';
    for (var i = 0; i < MANAGEMENT_PERMISSIONS.length; i++) {
        if (perms.indexOf(MANAGEMENT_PERMISSIONS[i]) !== -1)
            return 'custom';
    }
    return 'user';
};

/** Name used to greet someone: nickname, else first name, else a fallback. */
var displayNameOf = function displayNameOf(user) {
    if (!user)
        return '';
    var a = user.attributes || {};
    var nick  = (a['bg-nickname']   || '').trim();
    var first = (a['bg-first-name'] || '').trim();
    if (nick)  return nick;
    if (first) return first;
    var full = (a['guac-full-name'] || '').trim();
    if (full)  return full.split(/\s+/)[0];
    var name = user.username || '';
    return name.indexOf('@') > 0 ? name.substring(0, name.indexOf('@')) : name;
};

/**
 * Initials for the round picture when someone has no photo: first and last
 * name, else the words of their full name or nickname, else their sign-in name.
 */
var initialsOf = function initialsOf(user) {
    if (!user)
        return '?';
    var a = user.attributes || {};
    var first = (a['bg-first-name'] || '').trim();
    var last  = (a['bg-last-name']  || '').trim();
    var words;
    if (first || last)
        words = [first, last].filter(Boolean);
    else {
        var full = (a['guac-full-name'] || a['bg-nickname'] || '').trim();
        if (full)
            words = full.split(/\s+/);
        else {
            var name = user.username || '';
            if (name.indexOf('@') > 0)
                name = name.substring(0, name.indexOf('@'));
            words = name.split(/[._\-\s]+/).filter(Boolean);
        }
    }
    if (!words.length)
        return '?';
    var out = words[0].charAt(0);
    if (words.length > 1)
        out += words[words.length - 1].charAt(0);
    return out.toUpperCase();
};

/** Finds the nearest scope (this one or a parent) that owns the given function. */
var findOwner = function findOwner(scope, name) {
    var s = scope;
    while (s && !Object.prototype.hasOwnProperty.call(s, name))
        s = s.$parent;
    return s || null;
};

/* ---------------------------------------------------------------------
 * Session service: current user's role and profile
 * ------------------------------------------------------------------- */

angular.module('index').factory('bgSession', ['$injector', '$rootScope', '$q',
        function bgSession($injector, $rootScope, $q) {

    var authenticationService = $injector.get('authenticationService');
    var permissionService     = $injector.get('permissionService');
    var userService           = $injector.get('userService');

    var state = {};

    var reset = function reset() { state = {}; };
    $rootScope.$on('guacLogin',  reset);
    $rootScope.$on('guacLogout', reset);

    var current = function current() {
        var token    = authenticationService.getCurrentToken();
        var username = authenticationService.getCurrentUsername();
        var ds       = authenticationService.getDataSource();
        if (!token || !username || !ds || authenticationService.isAnonymous())
            return null;
        if (state.token !== token)
            state = { token : token, username : username, dataSource : ds };
        return state;
    };

    var service = {};

    service.dataSource = function dataSource() {
        var s = current();
        return s ? s.dataSource : null;
    };

    /** Promise of whether the signed-in user is an Admin. */
    service.isAdmin = function isAdmin() {
        var s = current();
        if (!s)
            return $q.resolve(false);
        if (!s.adminPromise) {
            s.adminPromise = permissionService.getEffectivePermissions(s.dataSource, s.username)
            .then(function (perms) {
                s.admin = (perms.systemPermissions || []).indexOf('ADMINISTER') !== -1;
                return s.admin;
            }, function () {
                s.admin = false;
                return false;
            });
        }
        return s.adminPromise;
    };

    /** Admin flag for templates: true / false, or null while loading. */
    service.adminNow = function adminNow() {
        var s = current();
        if (!s)
            return false;
        if (!s.adminPromise)
            service.isAdmin();
        return (s.admin === undefined) ? null : s.admin;
    };

    /** Promise of the signed-in user's own user object (with attributes). */
    service.self = function self(refresh) {
        var s = current();
        if (!s)
            return $q.reject();
        if (!s.selfPromise || refresh) {
            s.selfPromise = userService.getUser(s.dataSource, s.username).then(function (user) {
                s.selfUser = user;
                return user;
            });
        }
        return s.selfPromise;
    };

    service.selfNow = function selfNow() {
        var s = current();
        if (!s)
            return null;
        if (!s.selfPromise)
            service.self();
        return s.selfUser || null;
    };

    service.forgetSelf = function forgetSelf() {
        var s = current();
        if (s) { s.selfPromise = null; }
    };

    return service;

}]);

/* ---------------------------------------------------------------------
 * Settings tabs and user menu follow the role model; management pages
 * are hidden from (and redirect away for) Users.
 * ------------------------------------------------------------------- */

var TAB_ORDER = ['users', 'connections', 'sessions', 'history', 'userGroups', 'preferences'];
var ADMIN_TABS = ['users', 'connections', 'preferences'];

var tabOf = function tabOf(url) {
    var m = /\/settings\/(?:[^\/]+\/)?(users|userGroups|connections|history|sessions|preferences)$/.exec(url || '');
    return m ? m[1] : null;
};

angular.module('index').config(['$provide', '$httpProvider', function bgConfig($provide, $httpProvider) {

    /*
     * No placeholder keys on screen. Until Guacamole's translations arrive,
     * angular-translate hands back the raw key, so the tab title read
     * "APP.NAME" for a moment on every load. The page body is already hidden
     * until then (ng-cloak + translate-cloak on <body>); the title is the one
     * binding outside it. While translations are not ready, an unset value or
     * APP.NAME becomes "BetterGuac", any other untranslated key is blank, and
     * APP.NAME never shows as itself even if a translation goes missing.
     * index.html also carries a static <title>BetterGuac</title> for the
     * moment before any script runs.
     */
    $provide.decorator('translateFilter', ['$delegate', '$injector', function ($delegate, $injector) {
        var KEY = /^[A-Z][A-Z0-9_]*(\.[A-Z0-9_]+)+$/;
        var bgTranslateFilter = function bgTranslateFilter(id) {
            var out = $delegate.apply(this, arguments);
            if (out === 'APP.NAME')
                return 'BetterGuac';
            var $translate = $injector.get('$translate');
            if (!($translate.isReady && $translate.isReady())) {
                // page.title is still unset in the first digest: an empty title
                // would make the tab show the address instead
                if (id === undefined || id === null || id === '')
                    return 'BetterGuac';
                if (typeof id === 'string' && out === id && KEY.test(id))
                    return '';
            }
            return out;
        };
        bgTranslateFilter.$stateful = $delegate.$stateful;
        return bgTranslateFilter;
    }]);

    $provide.decorator('userPageService', ['$delegate', '$injector', function ($delegate, $injector) {

        var bgSession      = $injector.get('bgSession');
        var PageDefinition = $injector.get('PageDefinition');

        var originalSettingsPages = $delegate.getSettingsPages;
        var originalMainPages     = $delegate.getMainPages;

        var arrangeSettingsPages = function arrangeSettingsPages(pages, admin) {
            pages = (pages || []).filter(function (page) {
                var tab = tabOf(page.url);
                // Admin: user management, server management and their own
                // profile. User: their own profile only.
                return admin ? ADMIN_TABS.indexOf(tab) !== -1 : tab === 'preferences';
            });
            pages.sort(function (a, b) {
                var ia = TAB_ORDER.indexOf(tabOf(a.url)), ib = TAB_ORDER.indexOf(tabOf(b.url));
                return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib);
            });
            pages.forEach(function (page) {
                if (tabOf(page.url) === 'preferences')
                    page.name = 'BETTERGUAC.ACTION_MY_PROFILE';
            });
            return pages;
        };

        $delegate.getSettingsPages = function getSettingsPages() {
            return originalSettingsPages.apply($delegate, arguments).then(function (pages) {
                return bgSession.isAdmin().then(function (admin) {
                    return arrangeSettingsPages(pages, admin);
                });
            });
        };

        var HOME = function HOME() {
            return new PageDefinition({ name : 'USER_MENU.ACTION_NAVIGATE_HOME', url : '/' });
        };

        // Always land on the home screen (with the greeting), even when a
        // User has only one server: stock Guacamole would open that server
        // straight away
        var originalHomePage = $delegate.getHomePage;
        $delegate.getHomePage = function getHomePage() {
            return originalHomePage.apply($delegate, arguments).then(function (page) {
                return (page && /^\/client\//.test(page.url || '')) ? HOME() : page;
            });
        };

        $delegate.getMainPages = function getMainPages() {
            return originalMainPages.apply($delegate, arguments).then(function (pages) {
                return bgSession.isAdmin().then(function (admin) {
                    return (pages || []).map(function (page) {
                        if (/^\/client\//.test(page.url || ''))
                            return HOME();
                        if (!/^\/settings\//.test(page.url || ''))
                            return page;
                        if (!admin)
                            return new PageDefinition({
                                name : 'BETTERGUAC.ACTION_MY_PROFILE',
                                url  : '/settings/preferences'
                            });
                        return new PageDefinition({
                            name : 'BETTERGUAC.ACTION_MANAGE',
                            url  : '/settings/users'
                        });
                    });
                });
            });
        };

        return $delegate;

    }]);

    // Sign-in by email: send the email in lower case, without stray spaces
    $httpProvider.interceptors.push(function bgLoginInterceptor() {
        return {
            request : function (config) {
                try {
                    if (config && config.method === 'POST' && /(^|\/)api\/tokens$/.test(config.url || '')
                            && typeof config.data === 'string' && config.data.indexOf('username=') !== -1) {
                        var params = new URLSearchParams(config.data);
                        var name = params.get('username');
                        if (name && name.indexOf('@') !== -1) {
                            params.set('username', name.trim().toLowerCase());
                            config.data = params.toString();
                        }
                    }
                }
                catch (e) { /* leave the request as it is */ }
                return config;
            }
        };
    });

}]);

angular.module('index').run(['$injector', function bgRun($injector) {

    // Browser tab icon, home-screen icon and theme colour: the avocado, not Guacamole's
    (function bgIcons() {
        var head = document.head;
        var base = 'app/ext/betterguac-ui/';
        Array.prototype.forEach.call(head.querySelectorAll('link[rel="icon"], link[rel="apple-touch-icon"], link[rel="shortcut icon"]'),
            function (l) { l.parentNode.removeChild(l); });
        [['icon', '32x32', 'betterguac-icon-32.png'], ['icon', '64x64', 'betterguac-icon-64.png'],
         ['icon', '192x192', 'betterguac-icon-192.png'], ['apple-touch-icon', '180x180', 'betterguac-icon-180.png']]
            .forEach(function (d) {
                var l = document.createElement('link');
                l.rel = d[0]; l.type = 'image/png'; l.sizes = d[1]; l.href = base + d[2];
                l.setAttribute('data-bg-icon', '1');
                head.appendChild(l);
            });
        var t = head.querySelector('meta[name="theme-color"]') || document.createElement('meta');
        t.name = 'theme-color'; t.content = '#0c1530';
        head.appendChild(t);
        var a = head.querySelector('meta[name="apple-mobile-web-app-title"]') || document.createElement('meta');
        a.name = 'apple-mobile-web-app-title'; a.content = 'BetterGuac';
        head.appendChild(a);
    })();

    var $rootScope = $injector.get('$rootScope');
    var $location  = $injector.get('$location');
    var bgSession  = $injector.get('bgSession');

    var MANAGEMENT_PATH = /^\/(manage|import)\/|^\/settings\/(?:[^\/]+\/)?(users|userGroups|connections|history|sessions)$/;

    // Users never stay on a management page, even by typing its address
    $rootScope.$on('$routeChangeSuccess', function () {
        var path = $location.path();
        if (!MANAGEMENT_PATH.test(path))
            return;
        bgSession.isAdmin().then(function (admin) {
            if (!admin && $location.path() === path)
                $location.url('/settings/preferences').replace();
        });
    });

    // A server opened from the home pencil goes back home after Save,
    // Cancel or Delete instead of to the server list
    var fromHome = null;
    $rootScope.$on('$locationChangeStart', function (event, newUrl) {
        var hash = (newUrl.split('#')[1] || '');
        var path = hash.split('?')[0];
        var conn = /^\/manage\/[^\/]+\/connections\/([^\/?]+)$/.exec(path);
        if (conn && /[?&]from=home(&|$)/.test(hash)) {
            fromHome = conn[1];
            return;
        }
        if (fromHome && /^\/settings\/[^\/]+\/connections$/.test(path)) {
            fromHome = null;
            event.preventDefault();
            $location.url('/');
            return;
        }
        if (!conn)
            fromHome = null;
    });

}]);

/* ---------------------------------------------------------------------
 * Home screen
 * ------------------------------------------------------------------- */

angular.module('home').controller('bgGreetingController', ['$scope', '$injector',
        function bgGreetingController($scope, $injector) {

    var bgSession = $injector.get('bgSession');

    $scope.bgSelf = function bgSelf() { return bgSession.selfNow(); };

    $scope.bgName = function bgName() { return displayNameOf(bgSession.selfNow()); };

    // "Welcome back, Robert": the nickname or first name when one is on file,
    // otherwise just "Welcome back" (never the raw email or username)
    $scope.bgFirstName = function bgFirstName() {
        var u = bgSession.selfNow();
        var a = (u && u.attributes) || {};
        var name = (a['bg-nickname'] || '').trim() || (a['bg-first-name'] || '').trim();
        if (!name && (a['guac-full-name'] || '').trim())
            name = a['guac-full-name'].trim().split(/\s+/)[0];
        return name;
    };

    $scope.bgAvatar = function bgAvatar() {
        var u = bgSession.selfNow();
        return (u && u.attributes && u.attributes['bg-avatar']) || null;
    };

    $scope.bgInitial = function bgInitial() { return initialsOf(bgSession.selfNow()); };

    $scope.bgIsAdmin = function bgIsAdmin() { return bgSession.adminNow() === true; };

    // Always show the latest name and picture after a profile change
    bgSession.self(true);

}]);

/**
 * The signed-in person's own open sessions, from the server (so sessions
 * opened in another tab or on another device count too). Admins and
 * standard users alike only get their own here.
 */
angular.module('home').factory('bgMySessions', ['$injector', function bgMySessionsFactory($injector) {

    var $q                    = $injector.get('$q');
    var $interval             = $injector.get('$interval');
    var authenticationService = $injector.get('authenticationService');

    var state = { byServer : {}, loaded : false };
    var dataSources = {};
    var poller = null, users = 0;

    var refresh = function refresh() {
        var list = Object.keys(dataSources);
        if (!list.length || !authenticationService.getCurrentToken())
            return $q.when(state);
        return $q.all(list.map(function (ds) {
            return authenticationService.request({
                method : 'GET',
                url    : 'api/session/ext/' + encodeURIComponent(ds) + '/sessions'
            }).then(function (sessions) {
                return { ds : ds, sessions : sessions || [] };
            }, function () { return { ds : ds, sessions : null }; });
        })).then(function (all) {
            var byServer = {};
            all.forEach(function (r) {
                if (r.sessions === null) {
                    // Keep what we had for this source if one refresh fails
                    Object.keys(state.byServer).forEach(function (k) {
                        if (k.indexOf(r.ds + '/') === 0) byServer[k] = state.byServer[k];
                    });
                    return;
                }
                r.sessions.forEach(function (sess) {
                    var k = r.ds + '/' + sess.connectionIdentifier;
                    (byServer[k] = byServer[k] || []).push(sess);
                });
            });
            Object.keys(byServer).forEach(function (k) {
                byServer[k].sort(function (a, b) { return (a.startDate || 0) - (b.startDate || 0); });
            });
            state.byServer = byServer;
            state.loaded = true;
            return state;
        });
    };

    return {
        state : state,
        refresh : refresh,
        watch : function watch(dataSource) {
            if (!dataSources[dataSource]) {
                dataSources[dataSource] = true;
                refresh();
            }
            users++;
            if (!poller)
                poller = $interval(refresh, 8000);
            return function unwatch() {
                users--;
                if (users <= 0 && poller) {
                    $interval.cancel(poller);
                    poller = null;
                    users = 0;
                }
            };
        },
        sessionsFor : function sessionsFor(dataSource, connectionId) {
            return state.byServer[dataSource + '/' + connectionId] || [];
        },
        end : function end(dataSource, sessions) {
            return $q.all(sessions.map(function (sess) {
                return authenticationService.request({
                    method : 'DELETE',
                    url    : 'api/session/ext/' + encodeURIComponent(dataSource) + '/sessions/' + encodeURIComponent(sess.id)
                }).catch(function () { return null; });
            })).then(refresh);
        }
    };

}]);

/**
 * One server row on the home screen: Resume / Disconnect for a server that
 * has an open session (in this browser or anywhere else the same person
 * signed in), and the pencil (Admins only) that opens the editor.
 */
angular.module('home').controller('bgConnectionRowController', ['$scope', '$injector', '$element',
        function bgConnectionRowController($scope, $injector, $element) {

    // Narrow rows: when the buttons no longer fit beside the name they wrap
    // onto their own line; mark the row so they line up under the name text
    (function bgWatchWrap() {
        var row = $element[0];
        if (!row || typeof ResizeObserver === 'undefined')
            return;
        var check = function check() {
            var name = row.querySelector('.bg-name');
            var actions = row.querySelector('.bg-actions');
            if (!name || !actions)
                return;
            row.classList.remove('bg-wrapped');
            var wrapped = actions.offsetTop >= name.offsetTop + name.offsetHeight - 2;
            row.classList.toggle('bg-wrapped', wrapped);
        };
        var ro = new ResizeObserver(function () { window.requestAnimationFrame(check); });
        ro.observe(row);
        var actions = row.querySelector('.bg-actions');
        if (actions) ro.observe(actions);
        $scope.$on('$destroy', function () { ro.disconnect(); });
    })();

    var $location         = $injector.get('$location');
    var guacClientManager = $injector.get('guacClientManager');
    var bgSession         = $injector.get('bgSession');
    var bgMySessions      = $injector.get('bgMySessions');
    var ClientIdentifier  = $injector.get('ClientIdentifier');

    var OPEN_STATES = { CONNECTING : true, WAITING : true, CONNECTED : true };

    if ($scope.item && $scope.item.type === 'connection')
        $scope.$on('$destroy', bgMySessions.watch($scope.item.dataSource));

    var serverSessions = function serverSessions() {
        var item = $scope.item;
        if (!item || item.type !== 'connection')
            return [];
        return bgMySessions.sessionsFor(item.dataSource, item.identifier);
    };

    var getManagedClient = function getManagedClient() {
        var item = $scope.item;
        if (!item || item.type !== 'connection')
            return null;
        var id = item.getClientIdentifier();
        if (!id)
            return null;
        return guacClientManager.getManagedClients()[id] || null;
    };

    var isOpenHere = function isOpenHere() {
        var client = getManagedClient();
        return !!(client && client.clientState
                && OPEN_STATES[client.clientState.connectionState]);
    };

    $scope.bgIsOpen = function bgIsOpen() {
        return isOpenHere() || serverSessions().length > 0;
    };

    $scope.bgEnding = false;

    // Rejoin: the copy still running in this browser if there is one, else
    // join the session itself (opened in another tab or on another device)
    $scope.bgResume = function bgResume($event) {
        if ($event) { $event.preventDefault(); $event.stopPropagation(); }
        var item = $scope.item;
        if (isOpenHere()) {
            $location.url('/client/' + encodeURIComponent(item.getClientIdentifier()));
            return;
        }
        var sessions = serverSessions();
        if (!sessions.length)
            return;
        $location.url('/client/' + encodeURIComponent(ClientIdentifier.toString({
            dataSource : item.dataSource,
            type       : ClientIdentifier.Types.ACTIVE_CONNECTION,
            id         : sessions[0].id
        })));
    };

    // End it: closes the copy in this browser and every session this person
    // has open on this server (only their own: the server checks that)
    $scope.bgEnd = function bgEnd($event) {
        if ($event) { $event.preventDefault(); $event.stopPropagation(); }
        var item = $scope.item;
        $scope.bgEnding = true;
        var id = item.getClientIdentifier();
        if (id && guacClientManager.getManagedClients()[id])
            guacClientManager.removeManagedClient(id);
        // A rejoined copy has its own client id; close those too
        serverSessions().forEach(function (sess) {
            var aid = ClientIdentifier.toString({ dataSource : item.dataSource, type : ClientIdentifier.Types.ACTIVE_CONNECTION, id : sess.id });
            if (guacClientManager.getManagedClients()[aid])
                guacClientManager.removeManagedClient(aid);
        });
        bgMySessions.end(item.dataSource, serverSessions()).finally(function () {
            $scope.bgEnding = false;
        });
    };

    $scope.bgCanEdit = function bgCanEdit() {
        var item = $scope.item;
        return !!(item && item.type === 'connection' && bgSession.adminNow() === true);
    };

    // Straight into this server's editor; Save / Cancel come back home
    $scope.bgEditURL = function bgEditURL() {
        var item = $scope.item;
        return '#/manage/' + encodeURIComponent(item.dataSource)
             + '/connections/' + encodeURIComponent(item.identifier) + '?from=home';
    };

    // Template look: a terminal tile for SSH / telnet / Kubernetes, a monitor
    // tile for RDP / VNC, and a plain-words type line under the name
    var KINDS = {
        ssh        : { kind : 'terminal', label : 'Terminal' },
        telnet     : { kind : 'terminal', label : 'Terminal' },
        kubernetes : { kind : 'terminal', label : 'Kubernetes terminal' },
        rdp        : { kind : 'desktop',  label : 'Remote desktop' },
        vnc        : { kind : 'desktop',  label : 'Remote desktop' }
    };

    $scope.bgKind = function bgKind() {
        var k = KINDS[($scope.item && $scope.item.protocol) || ''];
        return k ? k.kind : 'other';
    };

    $scope.bgTypeLabel = function bgTypeLabel() {
        var proto = ($scope.item && $scope.item.protocol) || '';
        var k = KINDS[proto];
        return k ? k.label : (proto ? proto.toUpperCase() : 'Server');
    };

}]);

/* ---------------------------------------------------------------------
 * Home: "Your servers" panel header count and the empty state.
 * Counts every connection the person can see (inside folders too); while
 * the search box narrows the list it shows "2 of 15 connections".
 * ------------------------------------------------------------------- */
angular.module('home').controller('bgServerCountController', ['$scope', '$injector',
        function bgServerCountController($scope, $injector) {

    var bgSession = $injector.get('bgSession');

    var countIn = function countIn(group) {
        if (!group)
            return 0;
        var n = (group.childConnections || []).length;
        (group.childConnectionGroups || []).forEach(function (g) { n += countIn(g); });
        return n;
    };

    var countAll = function countAll(roots) {
        if (!roots)
            return null;
        var n = 0;
        angular.forEach(roots, function (g) { n += countIn(g); });
        return n;
    };

    $scope.bgTotal = function bgTotal() { return countAll($scope.rootConnectionGroups); };

    $scope.bgShown = function bgShown() {
        var f = countAll($scope.filteredRootConnectionGroups);
        return f === null ? $scope.bgTotal() : f;
    };

    $scope.bgCountText = function bgCountText() {
        var total = $scope.bgTotal();
        if (total === null)
            return '';
        var word = total === 1 ? ' connection' : ' connections';
        var shown = $scope.bgShown();
        return (shown !== total ? shown + ' of ' : '') + total + word;
    };

    $scope.bgIsAdmin = function bgIsAdmin() { return bgSession.adminNow() === true; };

    // Search only earns its space once the list is long enough to need it
    $scope.bgNeedsSearch = function bgNeedsSearch() { return ($scope.bgTotal() || 0) > 6; };

    $scope.bgServersURL = function bgServersURL() {
        var ds = $scope.rootConnectionGroups ? Object.keys($scope.rootConnectionGroups)[0] : null;
        return ds ? '#/settings/' + encodeURIComponent(ds) + '/connections' : '#/settings';
    };

}]);

/* ---------------------------------------------------------------------
 * Settings > Servers: richer rows
 * ------------------------------------------------------------------- */

var PROTOCOL_LABELS = { rdp : 'RDP', ssh : 'SSH', vnc : 'VNC', telnet : 'Telnet', kubernetes : 'Kubernetes' };

angular.module('settings').controller('bgServerRowController', ['$scope', '$element', '$injector',
        function bgServerRowController($scope, $element, $injector) {

    var $location         = $injector.get('$location');
    var $timeout          = $injector.get('$timeout');
    var connectionService = $injector.get('connectionService');

    var item = $scope.item;

    $scope.bgProtocol = function bgProtocol() {
        return item ? (PROTOCOL_LABELS[item.protocol] || item.protocol || '') : '';
    };

    $scope.bgDetails = null;
    if (item && item.type === 'connection') {
        connectionService.getConnectionParameters(item.dataSource, item.identifier)
        .then(function (params) {
            var host = params.hostname || '';
            var port = params.port || '';
            $scope.bgDetails = {
                address  : host ? (port ? host + ':' + port : host) : '',
                username : params.username || ''
            };
        }, function () { $scope.bgDetails = null; });
    }

    $scope.bgEditURL = function bgEditURL() {
        return '#/manage/' + encodeURIComponent(item.dataSource)
             + '/connections/' + encodeURIComponent(item.identifier);
    };

    // Highlight a server when the page was opened with ?server=<id>
    var target = $location.search().server;
    $scope.bgFocused = !!(target && item && item.type === 'connection'
        && String(item.identifier) === String(target));
    if ($scope.bgFocused) {
        $timeout(function scrollToServer() {
            var el = $element[0];
            if (el && el.scrollIntoView)
                el.scrollIntoView({ block : 'center' });
        }, 50);
    }

}]);

/* ---------------------------------------------------------------------
 * Settings > Users: compact rows with role, MFA and assigned servers
 * ------------------------------------------------------------------- */

angular.module('settings').controller('bgUserRowController', ['$scope', '$injector',
        function bgUserRowController($scope, $injector) {

    var permissionService = $injector.get('permissionService');
    var membershipService = $injector.get('membershipService');

    var mu = $scope.manageableUser;
    $scope.bgRole = null;
    $scope.bgAssigned = null;
    $scope.bgGroups = [];

    var load = function load() {
        if (!mu || !mu.user)
            return;
        permissionService.getPermissions(mu.dataSource, mu.user.username).then(function (perms) {
            $scope.bgRole = roleOf(perms.systemPermissions);
        }, function () {
            $scope.bgRole = 'unknown';
        });
        // Count includes servers reached through server groups
        permissionService.getEffectivePermissions(mu.dataSource, mu.user.username).then(function (perms) {
            var count = 0;
            angular.forEach(perms.connectionPermissions || {}, function (types) {
                if (types && types.indexOf('READ') !== -1)
                    count++;
            });
            $scope.bgAssigned = count;
        });
        membershipService.getUserGroups(mu.dataSource, mu.user.username).then(function (ids) {
            $scope.bgGroups = (ids || []).filter(function (id) { return id.indexOf(SG_PREFIX) === 0; })
                .map(function (id) { return id.substring(SG_PREFIX.length); }).sort();
        });
    };

    $scope.$watch('manageableUser', function (value) {
        mu = value;
        load();
    });

    $scope.bgMfa = function bgMfa() {
        var a = (mu && mu.user && mu.user.attributes) || {};
        if (a['guac-totp-disabled'] === 'true')
            return 'off';
        if (a['guac-totp-key-confirmed'] === 'true')
            return 'on';
        return 'pending';
    };

    $scope.bgDisplayName = function bgDisplayName() {
        var a = (mu && mu.user && mu.user.attributes) || {};
        var first = (a['bg-first-name'] || '').trim();
        var last  = (a['bg-last-name']  || '').trim();
        var name  = (first + ' ' + last).trim();
        return name || (a['guac-full-name'] || '').trim();
    };

    $scope.bgAvatar = function bgAvatar() {
        var a = (mu && mu.user && mu.user.attributes) || {};
        return a['bg-avatar'] || null;
    };

    $scope.bgInitial = function bgInitial() { return initialsOf(mu && mu.user); };

    $scope.bgEditURL = function bgEditURL() {
        return '#/manage/' + encodeURIComponent(mu.dataSource)
             + '/users/' + encodeURIComponent(mu.user.username);
    };

}]);

/* ---------------------------------------------------------------------
 * User editor: Role (Admin / User), own-password permission, email
 * sign-in name for new accounts
 * ------------------------------------------------------------------- */

angular.module('manage').controller('bgUserRoleController', ['$scope', '$element', '$injector',
        function bgUserRoleController($scope, $element, $injector) {

    var $q                    = $injector.get('$q');
    var authenticationService = $injector.get('authenticationService');
    var PermissionSet         = $injector.get('PermissionSet');
    var RestError             = $injector.get('Error');

    $scope.bgRoleModel = { value : null };
    $scope.bgOwnPassword = { value : false };
    $scope.bgAdvanced = false;

    // The stock checkbox editor stays available behind a toggle
    $scope.bgToggleAdvanced = function bgToggleAdvanced() {
        $scope.bgAdvanced = !$scope.bgAdvanced;
        var el = $element[0].closest ? $element[0].closest('.manage-user') : null;
        if (el)
            angular.element(el).toggleClass('bg-show-advanced', $scope.bgAdvanced);
    };

    var addSystem = function addSystem(type) {
        if (PermissionSet.hasSystemPermission($scope.permissionsRemoved, type))
            PermissionSet.removeSystemPermission($scope.permissionsRemoved, type);
        else
            PermissionSet.addSystemPermission($scope.permissionsAdded, type);
    };

    var removeSystem = function removeSystem(type) {
        if (PermissionSet.hasSystemPermission($scope.permissionsAdded, type))
            PermissionSet.removeSystemPermission($scope.permissionsAdded, type);
        else
            PermissionSet.addSystemPermission($scope.permissionsRemoved, type);
    };

    var addUser = function addUser(type, id) {
        if (PermissionSet.hasUserPermission($scope.permissionsRemoved, type, id))
            PermissionSet.removeUserPermission($scope.permissionsRemoved, type, id);
        else
            PermissionSet.addUserPermission($scope.permissionsAdded, type, id);
    };

    var removeUser = function removeUser(type, id) {
        if (PermissionSet.hasUserPermission($scope.permissionsAdded, type, id))
            PermissionSet.removeUserPermission($scope.permissionsAdded, type, id);
        else
            PermissionSet.addUserPermission($scope.permissionsRemoved, type, id);
    };

    var currentSystemPermissions = function currentSystemPermissions() {
        var flags = ($scope.permissionFlags && $scope.permissionFlags.systemPermissions) || {};
        return Object.keys(flags).filter(function (k) { return flags[k]; });
    };

    $scope.bgIsNew = function bgIsNew() { return $scope.selfUsername === 'SELF'; };

    // Your own role can't be changed here, so an Admin can't lock themselves out
    $scope.bgIsSelf = function bgIsSelf() {
        return !$scope.bgIsNew() && !!$scope.selfUsername
            && $scope.selfUsername === authenticationService.getCurrentUsername();
    };

    var initialized = false;
    $scope.$watch('permissionFlags', function (flags) {
        if (!flags)
            return;
        $scope.bgRoleModel.value = roleOf(currentSystemPermissions());
        var self = $scope.selfUsername;
        var userPerms = flags.userPermissions || {};
        $scope.bgOwnPassword.value = !!(userPerms.UPDATE && userPerms.UPDATE[self]);

        // New accounts start as a User who can change their own password
        if (!initialized && $scope.bgIsNew()) {
            initialized = true;
            if (!$scope.bgOwnPassword.value) {
                $scope.bgOwnPassword.value = true;
                $scope.bgOwnPasswordChanged();
            }
        }
        initialized = true;
    });

    $scope.bgSetRole = function bgSetRole(role) {
        if ($scope.bgIsSelf() || !$scope.permissionFlags)
            return;
        var flags = $scope.permissionFlags.systemPermissions;
        if (role === 'admin') {
            ADMIN_PERMISSIONS.forEach(function (type) {
                if (!flags[type]) { flags[type] = true; addSystem(type); }
            });
        }
        else if (role === 'user') {
            MANAGEMENT_PERMISSIONS.forEach(function (type) {
                if (flags[type]) { flags[type] = false; removeSystem(type); }
            });
        }
        $scope.bgRoleModel.value = roleOf(currentSystemPermissions());
    };

    $scope.bgOwnPasswordChanged = function bgOwnPasswordChanged() {
        if (!$scope.permissionFlags)
            return;
        var id = $scope.selfUsername;
        var userPerms = $scope.permissionFlags.userPermissions;
        if (!userPerms.UPDATE)
            userPerms.UPDATE = {};
        userPerms.UPDATE[id] = !!$scope.bgOwnPassword.value;
        if ($scope.bgOwnPassword.value)
            addUser('UPDATE', id);
        else
            removeUser('UPDATE', id);
    };

    // New accounts sign in with an email address (checked again on the server)
    var owner = findOwner($scope, 'saveUser');
    if (owner && !owner.saveUser.bgWrapped) {
        var originalSave = owner.saveUser;
        owner.saveUser = function bgSaveUser() {
            if (owner.selfUsername === 'SELF' && owner.user) {
                var email = (owner.user.username || '').trim().toLowerCase();
                if (!isEmail(email))
                    return $q.reject(new RestError({
                        translatableMessage : { key : 'BETTERGUAC.ERROR_EMAIL_REQUIRED' }
                    }));
                owner.user.username = email;
                owner.user.attributes = owner.user.attributes || {};
                owner.user.attributes['guac-email-address'] = email;
            }
            return originalSave.apply(this, arguments);
        };
        owner.saveUser.bgWrapped = true;
    }

}]);

/* ---------------------------------------------------------------------
 * Server editor: basics card, all-settings toggle, checks before Save,
 * and who the server is assigned to
 * ------------------------------------------------------------------- */

angular.module('manage').controller('bgServerEditorController', ['$scope', '$element', '$injector',
        function bgServerEditorController($scope, $element, $injector) {

    var $q                = $injector.get('$q');
    var $routeParams      = $injector.get('$routeParams');
    var userService       = $injector.get('userService');
    var permissionService = $injector.get('permissionService');
    var PermissionSet     = $injector.get('PermissionSet');
    var RestError         = $injector.get('Error');
    var bgSession         = $injector.get('bgSession');
    var bgServerGroups    = $injector.get('bgServerGroups');

    var dataSource = $routeParams.dataSource;
    var identifier = $routeParams.id;

    $scope.bgServerId = identifier || null;

    /* Server groups for this server */
    var groupState = null, savedGroupsKey = '';
    $scope.bgGroups = { text : '', names : [], access : [], loaded : false };
    var groupsKey = function (t) { return sgParse(t).map(function (n) { return n.toLowerCase(); }).sort().join('|'); };
    var loadGroups = function loadGroups() {
        return bgServerGroups.load(dataSource).then(function (state) {
            groupState = state;
            $scope.bgGroups.names = state.groups.map(function (g) { return g.name; });
            var mine = identifier ? (state.byConnection[String(identifier)] || []) : [];
            if (!$scope.bgGroups.loaded) {
                $scope.bgGroups.text = mine.join(', ');
                savedGroupsKey = groupsKey($scope.bgGroups.text);
            }
            $scope.bgGroups.access = state.groups.filter(function (g) {
                return mine.some(function (n) { return n.toLowerCase() === g.name.toLowerCase(); });
            });
            $scope.bgGroups.loaded = true;
        }, function () {
            $scope.bgGroups.error = true;
        });
    };
    bgSession.isAdmin().then(function (admin) { if (admin) loadGroups(); });
    $scope.bgShowAll = { value : false };

    var view = angular.element($element[0].closest ? $element[0].closest('.manage-connection') : null);
    $scope.$watch('bgShowAll.value', function (show) {
        if (view && view.length)
            view.toggleClass('bg-show-all', !!show);
    });
    view.addClass('bg-managed');

    $scope.bgIsRdp = function bgIsRdp() {
        return $scope.connection && $scope.connection.protocol === 'rdp';
    };

    $scope.bgPortPlaceholder = function bgPortPlaceholder() {
        var p = $scope.connection && $scope.connection.protocol;
        return { rdp : '3389', ssh : '22', vnc : '5900', telnet : '23', kubernetes : '8080' }[p] || '';
    };

    // The port has its own model: the stock numeric field (hidden, but still
    // live) would turn a half-typed value into an empty port
    $scope.bgPort = { value : '' };
    var lastPort = null;
    $scope.$watch('parameters.port', function (v) {
        var incoming = (v === undefined || v === null) ? '' : String(v);
        if (incoming !== lastPort) {
            lastPort = incoming;
            $scope.bgPort.value = incoming;
        }
    });
    $scope.bgPortChanged = function bgPortChanged() {
        if (!$scope.parameters)
            return;
        var v = String($scope.bgPort.value || '').trim();
        if (v === '') {
            lastPort = '';
            $scope.parameters.port = null;
        }
        else if (/^\d+$/.test(v) && +v >= 1 && +v <= 65535) {
            lastPort = v;
            $scope.parameters.port = v;
        }
    };

    $scope.bgCheck = function bgCheck() {
        var problems = [];
        var c = $scope.connection || {};
        var p = angular.extend({}, $scope.parameters || {}, { port : $scope.bgPort.value });
        if (!c.name || !String(c.name).trim())
            problems.push('BETTERGUAC.ERROR_SERVER_NAME');
        if (!p.hostname || !String(p.hostname).trim())
            problems.push('BETTERGUAC.ERROR_SERVER_HOST');
        else if (/\s/.test(String(p.hostname).trim()))
            problems.push('BETTERGUAC.ERROR_SERVER_HOST_SPACES');
        if (p.port !== undefined && p.port !== null && String(p.port).trim() !== '') {
            var port = String(p.port).trim();
            if (!/^\d+$/.test(port) || +port < 1 || +port > 65535)
                problems.push('BETTERGUAC.ERROR_SERVER_PORT');
        }
        if (sgProblem(sgParse($scope.bgGroups.text)))
            problems.push('BETTERGUAC.ERROR_GROUP_NAME');
        return problems;
    };

    /* SSH key as a file path: private-key-file holds the path and
     * private-key only a placeholder the server swaps for the file's text
     * when someone connects. */
    $scope.bgKey = { result : null, legacy : false };
    var bgSshKeys = $injector.get('bgSshKeys');
    var keyCheckSeq = 0;
    $scope.$watch('parameters["private-key"]', function (v) {
        $scope.bgKey.legacy = !!(v && v !== SSH_KEY_PLACEHOLDER);
    });
    $scope.bgKeyChanged = function bgKeyChanged() {
        $scope.bgKey.result = null;
    };
    $scope.bgKeyCheck = function bgKeyCheck() {
        var path = String(($scope.parameters || {})['private-key-file'] || '').trim();
        if (!path) {
            $scope.bgKey.result = null;
            return $q.when(null);
        }
        var local = sshKeyPathProblem(path);
        if (local) {
            $scope.bgKey.result = { ok : false, detail : local };
            return $q.when($scope.bgKey.result);
        }
        var seq = ++keyCheckSeq;
        return bgSshKeys.check(dataSource, [path]).then(function (res) {
            if (seq === keyCheckSeq)
                $scope.bgKey.result = res[0] || null;
            return res[0] || null;
        }, function () { return null; });
    };
    // The stock "Private key" box takes pasted key text: hide it, the path replaces it
    $scope.$watch(function () { var o = findOwner($scope, 'protocols'); return o && o.protocols && o.protocols.ssh; }, function (ssh) {
        if (!ssh || !ssh.connectionForms)
            return;
        ssh.connectionForms.forEach(function (form) {
            form.fields = (form.fields || []).filter(function (f) { return f.name !== 'private-key'; });
        });
    });
    var applyKeyFile = function applyKeyFile(params, protocol) {
        if (!params)
            return;
        var path = String(params['private-key-file'] || '').trim();
        if (protocol === 'ssh' && path) {
            params['private-key-file'] = path;
            params['private-key'] = SSH_KEY_PLACEHOLDER;
        }
        else {
            params['private-key-file'] = null;
            if (params['private-key'] === SSH_KEY_PLACEHOLDER || (protocol === 'ssh' && params['private-key']))
                params['private-key'] = null;
        }
    };

    var owner = findOwner($scope, 'saveConnection');
    if (owner && !owner.saveConnection.bgWrapped) {
        var originalSave = owner.saveConnection;
        owner.saveConnection = function bgSaveConnection() {
            var problems = $scope.bgCheck();
            if (problems.length)
                return $q.reject(new RestError({ translatableMessage : { key : problems[0] } }));
            if (owner.parameters && typeof owner.parameters.hostname === 'string')
                owner.parameters.hostname = owner.parameters.hostname.trim();
            $scope.bgPortChanged();
            var self = this, args = arguments;
            var keyPath = String((owner.parameters || {})['private-key-file'] || '').trim();
            var keyStep = (owner.connection && owner.connection.protocol === 'ssh' && keyPath) ? $scope.bgKeyCheck() : $q.when(null);
            return keyStep.then(function (keyRes) {
                if (keyRes && !keyRes.ok)
                    return $q.reject(new RestError({ message : keyRes.detail,
                        translatableMessage : { key : 'APP.TEXT_UNTRANSLATED', variables : { MESSAGE : keyRes.detail } } }));
                applyKeyFile(owner.parameters, owner.connection && owner.connection.protocol);
                return originalSave.apply(self, args);
            }).then(function (result) {
                var cid = owner.connection && owner.connection.identifier;
                if (!groupState || !cid || groupsKey($scope.bgGroups.text) === savedGroupsKey)
                    return result;
                return bgServerGroups.setServerGroups(dataSource, groupState, cid, sgParse($scope.bgGroups.text))
                .then(function () { return result; }, function () {
                    return $q.reject(new RestError({ translatableMessage : { key : 'BETTERGUAC.ERROR_GROUPS_NOT_SAVED' } }));
                });
            });
        };
        owner.saveConnection.bgWrapped = true;
    }

    // RDP "ignore server certificate" is stored as the string "true"
    $scope.bgIgnoreCert = { value : false };
    $scope.$watch('parameters["ignore-cert"]', function (v) { $scope.bgIgnoreCert.value = (v === 'true'); });
    $scope.bgIgnoreCertChanged = function bgIgnoreCertChanged() {
        if ($scope.parameters)
            $scope.parameters['ignore-cert'] = $scope.bgIgnoreCert.value ? 'true' : null;
    };

    /* Who can open this server (Users with READ). Admins see every server. */

    $scope.bgAssign = null;

    var loadAssignments = function loadAssignments() {
        if (!identifier)
            return;
        bgSession.isAdmin().then(function (admin) {
            if (!admin)
                return;
            userService.getUsers(dataSource).then(function (users) {
                users = users || {};
                var names = Object.keys(users).sort();
                return $q.all(names.map(function (name) {
                    return permissionService.getPermissions(dataSource, name).then(function (perms) {
                        var role = roleOf(perms.systemPermissions);
                        return {
                            username : name,
                            role     : role,
                            disabled : !!users[name].disabled,
                            assigned : PermissionSet.hasConnectionPermission(perms,
                                            PermissionSet.ObjectPermissionType.READ, identifier),
                            saving   : false,
                            status   : null
                        };
                    });
                }));
            }).then(function (rows) {
                $scope.bgAssign = {
                    users  : rows.filter(function (r) { return r.role !== 'admin'; }),
                    admins : rows.filter(function (r) { return r.role === 'admin'; })
                };
            }, function () {
                $scope.bgAssign = { error : true, users : [], admins : [] };
            });
        });
    };

    $scope.bgToggleAssignment = function bgToggleAssignment(row) {
        var change = new PermissionSet();
        PermissionSet.addConnectionPermission(change, PermissionSet.ObjectPermissionType.READ, identifier);
        var empty = new PermissionSet();
        row.saving = true;
        row.status = null;
        var request = row.assigned
            ? permissionService.patchPermissions(dataSource, row.username, change, empty)
            : permissionService.patchPermissions(dataSource, row.username, empty, change);
        request.then(function () {
            row.saving = false;
            row.status = 'saved';
        }, function () {
            row.saving = false;
            row.assigned = !row.assigned;
            row.status = 'failed';
        });
    };

    loadAssignments();

}]);

/* ---------------------------------------------------------------------
 * Preferences: profile (left) and MFA status (right)
 * ------------------------------------------------------------------- */

var resizeAvatar = function resizeAvatar(file, $q) {
    var deferred = $q.defer();
    if (!file || !/^image\/(png|jpeg|webp|gif)$/.test(file.type)) {
        deferred.reject('BETTERGUAC.ERROR_AVATAR_TYPE');
        return deferred.promise;
    }
    if (file.size > 10 * 1024 * 1024) {
        deferred.reject('BETTERGUAC.ERROR_AVATAR_FILE_SIZE');
        return deferred.promise;
    }
    var reader = new FileReader();
    reader.onerror = function () { deferred.reject('BETTERGUAC.ERROR_AVATAR_READ'); };
    reader.onload = function () {
        var img = new Image();
        img.onerror = function () { deferred.reject('BETTERGUAC.ERROR_AVATAR_READ'); };
        img.onload = function () {
            // Square crop from the centre, then shrink until it fits the
            // database's 4096-character attribute limit
            var side = Math.min(img.width, img.height);
            var sx = (img.width - side) / 2, sy = (img.height - side) / 2;
            var attempts = [[128, 0.85], [128, 0.7], [96, 0.75], [96, 0.6], [72, 0.6], [64, 0.5]];
            for (var i = 0; i < attempts.length; i++) {
                var size = attempts[i][0], quality = attempts[i][1];
                var canvas = document.createElement('canvas');
                canvas.width = canvas.height = size;
                var ctx = canvas.getContext('2d');
                ctx.fillStyle = '#16244f';
                ctx.fillRect(0, 0, size, size);
                ctx.drawImage(img, sx, sy, side, side, 0, 0, size, size);
                var url = canvas.toDataURL('image/jpeg', quality);
                if (url.length <= MAX_AVATAR_LENGTH - 96) {
                    deferred.resolve(url);
                    return;
                }
            }
            deferred.reject('BETTERGUAC.ERROR_AVATAR_TOO_BIG');
        };
        img.src = reader.result;
    };
    reader.readAsDataURL(file);
    return deferred.promise;
};

angular.module('settings').directive('bgAvatarInput', [function bgAvatarInput() {
    return {
        restrict : 'A',
        link : function (scope, element, attrs) {
            element.on('change', function () {
                var file = element[0].files && element[0].files[0];
                scope.$apply(function () { scope.$eval(attrs.bgAvatarInput, { $file : file }); });
                element[0].value = '';
            });
        }
    };
}]);

angular.module('settings').controller('bgProfileController', ['$scope', '$injector',
        function bgProfileController($scope, $injector) {

    var $q                    = $injector.get('$q');
    var $location             = $injector.get('$location');
    var authenticationService = $injector.get('authenticationService');
    var guacNotification      = $injector.get('guacNotification');
    var bgSession             = $injector.get('bgSession');

    $scope.bgAvatarError = null;
    $scope.bgSaving = false;

    var attrs = function attrs() {
        if (!$scope.user)
            return {};
        $scope.user.attributes = $scope.user.attributes || {};
        return $scope.user.attributes;
    };

    $scope.bgSignInIsEmail = function bgSignInIsEmail() {
        return !!($scope.user && isEmail($scope.user.username));
    };

    $scope.bgDisplayName = function bgDisplayName() { return displayNameOf($scope.user); };

    $scope.bgInitial = function bgInitial() { return initialsOf($scope.user); };

    $scope.bgPickAvatar = function bgPickAvatar(file) {
        if (!file)
            return;
        $scope.bgAvatarError = null;
        resizeAvatar(file, $q).then(function (url) {
            attrs()['bg-avatar'] = url;
        }, function (key) {
            $scope.bgAvatarError = key;
        });
    };

    $scope.bgRemoveAvatar = function bgRemoveAvatar() {
        // An empty value removes the stored picture
        attrs()['bg-avatar'] = null;
    };

    $scope.bgNameError = function bgNameError() {
        var a = attrs();
        var fields = ['bg-first-name', 'bg-last-name', 'bg-nickname'];
        for (var i = 0; i < fields.length; i++) {
            var v = a[fields[i]];
            if (v && String(v).length > MAX_NAME_LENGTH)
                return 'BETTERGUAC.ERROR_NAME_TOO_LONG';
        }
        return null;
    };

    $scope.bgSaveProfile = function bgSaveProfile() {
        if ($scope.bgNameError() || !$scope.user)
            return;
        var a = attrs();
        ['bg-first-name', 'bg-last-name', 'bg-nickname'].forEach(function (k) {
            if (typeof a[k] === 'string') {
                a[k] = a[k].trim();
                if (!a[k]) a[k] = null;
            }
        });
        var owner = findOwner($scope, 'saveUser');
        if (!owner)
            return;
        $scope.bgSaving = true;
        $q.when(owner.saveUser()).then(function () {
            bgSession.forgetSelf();
        })['finally'](function () {
            $scope.bgSaving = false;
        });
    };

    /* MFA status: read from the account itself (set by the TOTP extension
     * only after a code from the authenticator app has been verified). */

    // MFA status is read fresh from the server (not the page's cached copy),
    // so a reset by an admin shows up here straight away
    var $http = $injector.get('$http');
    $scope.bgServerAttrs = null;
    var refreshMfa = function refreshMfa() {
        var ds = authenticationService.getDataSource();
        var name = authenticationService.getCurrentUsername();
        if (!ds || !name)
            return;
        $http({
            method  : 'GET',
            url     : 'api/session/data/' + encodeURIComponent(ds) + '/users/' + encodeURIComponent(name),
            headers : { 'Guacamole-Token' : authenticationService.getCurrentToken() },
            cache   : false
        }).then(function (response) {
            $scope.bgServerAttrs = (response.data && response.data.attributes) || {};
        });
    };
    refreshMfa();

    $scope.bgMfa = function bgMfa() {
        var a = $scope.bgServerAttrs;
        if (!a)
            return 'loading';
        if (a['guac-totp-disabled'] === 'true')
            return 'off';
        if (a['guac-totp-key-confirmed'] === 'true')
            return 'on';
        return 'pending';
    };

    // Reset: the server checks the password and a current code, removes the
    // key, and we sign out so the sign-in screen enrolls a new one
    $scope.bgReset = { open : false, password : '', code : '' };
    $scope.bgResetMfa = function bgResetMfa() {
        var r = $scope.bgReset;
        r.busy = true;
        r.error = null;
        authenticationService.request({
            method : 'POST',
            url    : 'api/session/ext/' + encodeURIComponent(authenticationService.getDataSource()) + '/mfa/reset',
            data   : { password : r.password, code : r.code }
        }).then(function () {
            r.password = '';
            r.code = '';
            authenticationService.logout()['finally'](function () {
                $location.url('/');
            });
        }, function (err) {
            r.busy = false;
            r.code = '';
            r.error = (err && err.message) || "The reset didn't work.";
        });
    };

    // Enrollment happens on the sign-in screen: password first, then the QR
    // code, then a code from the app that the server verifies
    $scope.bgEnrollNow = function bgEnrollNow() {
        guacNotification.showStatus({
            title   : 'BETTERGUAC.DIALOG_HEADER_MFA_SETUP',
            text    : { key : 'BETTERGUAC.TEXT_MFA_SETUP' },
            actions : [{
                name     : 'BETTERGUAC.ACTION_MFA_SIGN_OUT',
                callback : function () {
                    guacNotification.showStatus(false);
                    authenticationService.logout()['finally'](function () {
                        $location.url('/');
                    });
                }
            }, {
                name      : 'BETTERGUAC.ACTION_CANCEL',
                className : 'cancel',
                callback  : function () { guacNotification.showStatus(false); }
            }]
        });
    };

}]);



/* ---------------------------------------------------------------------
 * Server groups. Each group is a Guacamole user group named
 * "Servers: <name>" that has READ on the servers in it. A server can be in
 * several groups; a User who is a member of any of them can open it.
 * ------------------------------------------------------------------- */

var SG_PREFIX = 'Servers: ';
var SG_MAX = 64;

/* "Proxmox, database; Lab" -> ['Proxmox', 'database', 'Lab'] (no repeats) */
var sgParse = function sgParse(text) {
    var seen = {}, out = [];
    String(text || '').split(/[,;]/).forEach(function (part) {
        var name = part.replace(/\s+/g, ' ').trim();
        if (name && !seen[name.toLowerCase()]) {
            seen[name.toLowerCase()] = true;
            out.push(name);
        }
    });
    return out;
};

var sgProblem = function sgProblem(names) {
    for (var i = 0; i < names.length; i++) {
        if (names[i].length > SG_MAX)
            return 'A group name can be at most ' + SG_MAX + ' characters.';
    }
    return null;
};

angular.module('index').factory('bgServerGroups', ['$injector', function bgServerGroupsFactory($injector) {

    var $q                = $injector.get('$q');
    var userGroupService  = $injector.get('userGroupService');
    var permissionService = $injector.get('permissionService');
    var membershipService = $injector.get('membershipService');
    var PermissionSet     = $injector.get('PermissionSet');
    var UserGroup         = $injector.get('UserGroup');

    var service = {};

    service.idOf = function idOf(name) { return SG_PREFIX + name; };

    /* All server groups with their servers and members */
    service.load = function load(dataSource) {
        return userGroupService.getUserGroups(dataSource).then(function (groups) {
            var ids = Object.keys(groups || {}).filter(function (id) { return id.indexOf(SG_PREFIX) === 0; });
            return $q.all(ids.map(function (id) {
                return $q.all([
                    permissionService.getPermissions(dataSource, id, true),
                    membershipService.getMemberUsers(dataSource, id)
                ]).then(function (got) {
                    var conns = [];
                    angular.forEach(got[0].connectionPermissions || {}, function (types, cid) {
                        if (types && types.indexOf('READ') !== -1)
                            conns.push(String(cid));
                    });
                    return {
                        id          : id,
                        name        : id.substring(SG_PREFIX.length),
                        connections : conns,
                        members     : (got[1] || []).slice().sort(),
                        disabled    : !!groups[id].disabled
                    };
                });
            }));
        }).then(function (list) {
            list.sort(function (a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1; });
            var byConnection = {}, byName = {};
            list.forEach(function (g) {
                byName[g.name.toLowerCase()] = g;
                g.connections.forEach(function (cid) {
                    (byConnection[cid] = byConnection[cid] || []).push(g.name);
                });
            });
            return { groups : list, byConnection : byConnection, byName : byName };
        });
    };

    /* An existing group's spelling wins over what was typed */
    service.canonical = function canonical(state, names) {
        return names.map(function (n) {
            var g = state && state.byName[n.toLowerCase()];
            return g ? g.name : n;
        });
    };

    var ensure = function ensure(dataSource, state, name) {
        var k = name.toLowerCase();
        var g = state.byName[k];
        if (g)
            return $q.when(g);
        // One creation per new group, even when several servers join it at once
        state.creating = state.creating || {};
        if (state.creating[k])
            return state.creating[k];
        var created = { id : service.idOf(name), name : name, connections : [], members : [] };
        // New groups are created one after another: MariaDB deadlocks when two group
        // creations write their permission rows at the same time.
        var prev = (state.createQueue || $q.when()).catch(angular.noop);
        state.creating[k] = prev.then(function () {
            return userGroupService.createUserGroup(dataSource, new UserGroup({ identifier : created.id, attributes : {} }));
        })
        .then(function () {
            state.byName[k] = created;
            state.groups.push(created);
            return created;
        }).finally(function () {
            delete state.creating[k];
        });
        state.createQueue = state.creating[k];
        return state.creating[k];
    };

    var connectionSet = function connectionSet(cid) {
        var set = new PermissionSet();
        PermissionSet.addConnectionPermission(set, PermissionSet.ObjectPermissionType.READ, String(cid));
        return set;
    };

    /* Puts one server in exactly these groups (creating new groups) */
    service.setServerGroups = function setServerGroups(dataSource, state, cid, names) {
        cid = String(cid);
        names = service.canonical(state, names);
        var want = {};
        names.forEach(function (n) { want[n.toLowerCase()] = n; });
        var have = {};
        (state.byConnection[cid] || []).forEach(function (n) { have[n.toLowerCase()] = n; });

        var jobs = [];
        Object.keys(want).forEach(function (k) {
            if (have[k])
                return;
            jobs.push(ensure(dataSource, state, want[k]).then(function (g) {
                return permissionService.patchPermissions(dataSource, g.id, connectionSet(cid), new PermissionSet(), true)
                .then(function () { g.connections.push(cid); });
            }));
        });
        Object.keys(have).forEach(function (k) {
            if (want[k])
                return;
            var g = state.byName[k];
            jobs.push(permissionService.patchPermissions(dataSource, g.id, new PermissionSet(), connectionSet(cid), true)
            .then(function () {
                g.connections = g.connections.filter(function (c) { return c !== cid; });
            }));
        });
        return $q.all(jobs).then(function () {
            state.byConnection[cid] = names.slice();
        });
    };

    /* Deletes one server group. Its servers stay; members lose the access it gave. */
    service.remove = function remove(dataSource, group) {
        return userGroupService.deleteUserGroup(dataSource, new UserGroup({ identifier : group.id }));
    };

    /* Adds or removes one user from one group */
    service.setMember = function setMember(dataSource, username, group, member) {
        return membershipService.patchUserGroups(dataSource, username,
            member ? [group.id] : [], member ? [] : [group.id]);
    };

    /*
     * Running sessions: Guacamole checks access only when a session starts,
     * so a session that is already open would keep going after its group
     * access is taken away. After any change here, end every running session
     * whose person can no longer read that server (admins are left alone).
     */
    var activeConnectionService = $injector.get('activeConnectionService');

    service.endLostSessions = function endLostSessions(dataSource) {
        return activeConnectionService.getActiveConnections(dataSource).then(function (active) {
            var byUser = {};
            angular.forEach(active, function (ac, id) {
                if (!ac || !ac.username || !ac.connectionIdentifier)
                    return;
                (byUser[ac.username] = byUser[ac.username] || []).push({ id : ac.identifier || id, cid : ac.connectionIdentifier });
            });
            var lost = [];
            return $q.all(Object.keys(byUser).map(function (username) {
                return permissionService.getEffectivePermissions(dataSource, username).then(function (perms) {
                    if (PermissionSet.hasSystemPermission(perms, PermissionSet.SystemPermissionType.ADMINISTER))
                        return;
                    byUser[username].forEach(function (s) {
                        if (!PermissionSet.hasConnectionPermission(perms, PermissionSet.ObjectPermissionType.READ, s.cid))
                            lost.push(s.id);
                    });
                }, angular.noop);
            })).then(function () {
                if (lost.length)
                    return activeConnectionService.deleteActiveConnections(dataSource, lost).then(function () { return lost.length; });
                return 0;
            });
        })['catch'](function () { return 0; });
    };

    // One check after a burst of changes (a list save changes many rows at
    // once); it runs in the background and never holds up the save itself.
    var $timeout = $injector.get('$timeout');
    var pendingCheck = null;
    var scheduleCheck = function scheduleCheck(dataSource) {
        if (pendingCheck)
            $timeout.cancel(pendingCheck);
        pendingCheck = $timeout(function () {
            pendingCheck = null;
            service.endLostSessions(dataSource);
        }, 600);
    };

    ['setMember', 'remove', 'setServerGroups'].forEach(function (name) {
        var original = service[name];
        if (!original)
            return;
        service[name] = function () {
            var dataSource = arguments[0];
            var result = original.apply(service, arguments);
            $q.when(result).then(function () { scheduleCheck(dataSource); }, function () { scheduleCheck(dataSource); });
            return result;
        };
    });

    return service;

}]);


/* ---------------------------------------------------------------------
 * User editor: server group membership (saves on each tick)
 * ------------------------------------------------------------------- */

angular.module('manage').controller('bgUserServerGroupsController', ['$scope', '$injector',
        function bgUserServerGroupsController($scope, $injector) {

    var $q                     = $injector.get('$q');
    var $routeParams           = $injector.get('$routeParams');
    var membershipService      = $injector.get('membershipService');
    var connectionGroupService = $injector.get('connectionGroupService');
    var ConnectionGroup        = $injector.get('ConnectionGroup');
    var bgServerGroups         = $injector.get('bgServerGroups');
    var bgSession              = $injector.get('bgSession');

    var dataSource = $routeParams.dataSource;
    var username   = $routeParams.id;

    $scope.bgSg = { isNew : !username, loaded : false, groups : [] };
    if (!username)
        return;

    bgSession.isAdmin().then(function (admin) {
        if (!admin)
            return;
        return $q.all([
            bgServerGroups.load(dataSource),
            membershipService.getUserGroups(dataSource, username),
            connectionGroupService.getConnectionGroupTree(dataSource, ConnectionGroup.ROOT_IDENTIFIER)
        ]).then(function (got) {
            var state = got[0], mine = got[1] || [], names = {};
            var walk = function (g) {
                (g.childConnections || []).forEach(function (c) { names[String(c.identifier)] = c.name; });
                (g.childConnectionGroups || []).forEach(walk);
            };
            walk(got[2]);
            $scope.bgSg.groups = state.groups.map(function (g) {
                return {
                    id          : g.id,
                    name        : g.name,
                    member      : mine.indexOf(g.id) !== -1,
                    serverNames : g.connections.map(function (cid) { return names[cid]; })
                                    .filter(function (n) { return !!n; }).sort()
                };
            });
            $scope.bgSg.loaded = true;
        });
    }).catch(function () {
        $scope.bgSg.error = true;
    });

    $scope.bgToggleGroup = function bgToggleGroup(g) {
        g.saving = true;
        g.status = null;
        bgServerGroups.setMember(dataSource, username, g, g.member).then(function () {
            g.status = 'saved';
        }, function () {
            g.member = !g.member;
            g.status = 'failed';
        }).finally(function () {
            g.saving = false;
        });
    };

}]);


/* ---------------------------------------------------------------------
 * Connectivity test, run on the BetterGuac server (admin only): TCP to the
 * host and port, then an SSH / VNC banner or an RDP handshake
 * ------------------------------------------------------------------- */

angular.module('index').factory('bgConnectivity', ['$injector', function bgConnectivityFactory($injector) {

    var $q                    = $injector.get('$q');
    var authenticationService = $injector.get('authenticationService');

    return {
        /* targets: [{ host, port, protocol }] -> same order, with ok / detail */
        check : function check(dataSource, targets) {
            if (!targets.length)
                return $q.when([]);
            return authenticationService.request({
                method : 'POST',
                url    : 'api/session/ext/' + encodeURIComponent(dataSource) + '/connectivity',
                data   : targets.map(function (t) {
                    return { host : String(t.host || '').trim(), port : String(t.port || '').trim(), protocol : t.protocol };
                })
            });
        }
    };

}]);


/* SSH key files: checks a key path on the BetterGuac server (admins only).
 * Answers ok / detail per path; the key itself never comes back. */
var SSH_KEY_PLACEHOLDER = '${BETTERGUAC_SSH_PRIVATE_KEY}';
var SSH_KEY_DIR = '/etc/betterguac/keys';

var sshKeyPathProblem = function sshKeyPathProblem(v) {
    v = String(v === undefined || v === null ? '' : v).trim();
    if (!v)
        return null;
    if (v.indexOf('-----BEGIN') !== -1 || /[\r\n]/.test(v))
        return 'Enter the path to the key file, not the key itself (like ' + SSH_KEY_DIR + '/web-01).';
    if (v.charAt(0) !== '/')
        return 'The key file needs a full path starting with /, like ' + SSH_KEY_DIR + '/web-01.';
    return null;
};

angular.module('index').factory('bgSshKeys', ['$injector', function bgSshKeysFactory($injector) {

    var $q                    = $injector.get('$q');
    var authenticationService = $injector.get('authenticationService');

    return {
        check : function check(dataSource, paths) {
            if (!paths.length)
                return $q.when([]);
            return authenticationService.request({
                method : 'POST',
                url    : 'api/session/ext/' + encodeURIComponent(dataSource) + '/sshkey/check',
                data   : paths.map(function (p) { return String(p || '').trim(); })
            });
        }
    };

}]);

/* ---------------------------------------------------------------------
 * User editor (admins): reset another person's two-factor sign-in
 * ------------------------------------------------------------------- */

angular.module('manage').controller('bgUserMfaController', ['$scope', '$injector',
        function bgUserMfaController($scope, $injector) {

    var $routeParams          = $injector.get('$routeParams');
    var authenticationService = $injector.get('authenticationService');
    var userService           = $injector.get('userService');
    var bgSession             = $injector.get('bgSession');

    var dataSource = $routeParams.dataSource;
    var username   = $routeParams.id;

    $scope.bgUm = { visible : false, username : username };

    var load = function load() {
        userService.getUser(dataSource, username).then(function (user) {
            var a = user.attributes || {};
            $scope.bgUm.enrolled = a['guac-totp-key-confirmed'] === 'true';
            $scope.bgUm.disabled = a['guac-totp-disabled'] === 'true';
            $scope.bgUm.visible = true;
        });
    };

    // Not for new users, and not for your own account (My profile does that)
    if (username && username !== authenticationService.getCurrentUsername())
        bgSession.isAdmin().then(function (admin) { if (admin) load(); });

    $scope.bgUmReset = function bgUmReset() {
        var um = $scope.bgUm;
        um.busy = true;
        um.result = null;
        authenticationService.request({
            method : 'POST',
            url    : 'api/session/ext/' + encodeURIComponent(dataSource) + '/mfa/reset-user',
            data   : { username : username }
        }).then(function (data) {
            um.failed = false;
            um.confirm = false;
            um.temporary = (data && data.temporaryPassword) || null;
            um.result = 'Reset. ' + username + ' signs in with the one-time password below, chooses a new password, then scans a new QR code.';
            load();
        }, function (err) {
            um.failed = true;
            um.result = (err && err.message) || "The reset didn't work.";
        })['finally'](function () {
            um.busy = false;
        });
    };

}]);

/* ---------------------------------------------------------------------
 * Settings > Servers: editable server list with add / delete rows and a
 * bulk editor that checks pasted lines and fills the list
 * ------------------------------------------------------------------- */

var SM_PROTOCOLS = ['ssh', 'rdp', 'vnc', 'telnet', 'kubernetes'];
var SM_DEFAULT_PORTS = { rdp : '3389', ssh : '22', vnc : '5900', telnet : '23', kubernetes : '8080' };
var SM_ALIASES = { k8s : 'kubernetes', 'remote desktop' : 'rdp', ms_rdp : 'rdp' };
var SM_HOST = /^[A-Za-z0-9._\-:\[\]%]+$/;
var smLastResult = null;

var smValidPort = function smValidPort(v) {
    v = String(v === undefined || v === null ? '' : v).trim();
    return v === '' || (/^\d+$/.test(v) && +v >= 1 && +v <= 65535);
};

var smHostProblem = function smHostProblem(h) {
    h = String(h || '').trim();
    if (!h)
        return 'Enter a host name or IP address.';
    if (/\s/.test(h))
        return "The host can't contain spaces.";
    if (!SM_HOST.test(h))
        return 'The host has characters that are not allowed.';
    return null;
};

/* Splits "host:port" (and "[v6]:port"); a bare IPv6 address stays whole */
var smSplitHost = function smSplitHost(h) {
    h = String(h || '').trim();
    var m = /^\[([^\]]+)\]:(\d+)$/.exec(h);
    if (m)
        return { host : '[' + m[1] + ']', port : m[2] };
    m = /^([^:]+):(\d*)$/.exec(h);
    if (m)
        return { host : m[1], port : m[2] };
    return { host : h, port : '' };
};

angular.module('settings').controller('bgServerManagerController', ['$scope', '$element', '$injector',
        function bgServerManagerController($scope, $element, $injector) {

    var $q                     = $injector.get('$q');
    var $route                 = $injector.get('$route');
    var connectionService      = $injector.get('connectionService');
    var connectionGroupService = $injector.get('connectionGroupService');
    var ConnectionGroup        = $injector.get('ConnectionGroup');
    var Connection             = $injector.get('Connection');
    var guacNotification       = $injector.get('guacNotification');
    var bgServerGroups         = $injector.get('bgServerGroups');
    var bgConnectivity         = $injector.get('bgConnectivity');
    var bgSshKeys              = $injector.get('bgSshKeys');

    var dataSource = $scope.dataSource;
    var keySeq = 0;
    var groupState = null;

    var section = angular.element($element[0].closest ? $element[0].closest('.settings.section.connections') : null);
    section.addClass('bg-sm-active');

    var blankRow = function blankRow() {
        return { name : '', protocol : 'ssh', hostname : '', port : '', username : '', password : '', keyfile : '', groups : '', problems : [] };
    };

    $scope.bgSm = {
        loaded   : false,
        rows     : [],
        blank    : blankRow(),
        bulkText : '',
        bulk     : null,
        classic  : false,
        filter   : { group : null, text : '' }
    };

    if (smLastResult) {
        $scope.bgSm.result = smLastResult.text;
        $scope.bgSm.resultBad = smLastResult.bad;
        smLastResult = null;
    }

    $scope.bgProtocols = SM_PROTOCOLS.map(function (p) { return { value : p, label : PROTOCOL_LABELS[p] || p }; });

    $scope.bgDefaultPort = function bgDefaultPort(p) { return SM_DEFAULT_PORTS[p] || ''; };

    $scope.bgProtoLabel = function bgProtoLabel(p) { return PROTOCOL_LABELS[p] || p || ''; };

    $scope.bgEditURL = function bgEditURL(row) {
        return '#/manage/' + encodeURIComponent(dataSource) + '/connections/' + encodeURIComponent(row.identifier);
    };

    $scope.bgToggleClassic = function bgToggleClassic() {
        $scope.bgSm.classic = !$scope.bgSm.classic;
        section.toggleClass('bg-sm-classic', $scope.bgSm.classic);
    };

    var FIELDS = ['name', 'protocol', 'hostname', 'port', 'username', 'keyfile'];

    var norm = function norm(v) { return String(v === undefined || v === null ? '' : v).trim(); };

    var groupsKey = function groupsKey(text) {
        return sgParse(text).map(function (n) { return n.toLowerCase(); }).sort().join('|');
    };

    var connChanged = function connChanged(row) {
        if (row.isNew || row.password)
            return true;
        for (var i = 0; i < FIELDS.length; i++) {
            if (norm(row[FIELDS[i]]) !== norm(row.original[FIELDS[i]]))
                return true;
        }
        return false;
    };

    var groupsChanged = function groupsChanged(row) {
        return groupsKey(row.groups) !== groupsKey(row.isNew ? '' : row.original.groups);
    };

    $scope.bgIsChanged = function bgIsChanged(row) {
        return connChanged(row) || groupsChanged(row);
    };

    /* Group filter: chips for every group in the list (unsaved edits too) */
    $scope.bgGroupChips = function bgGroupChips() {
        var counts = {}, names = {}, none = 0;
        $scope.bgSm.rows.forEach(function (row) {
            if (row.deleted)
                return;
            var list = sgParse(row.groups);
            if (!list.length)
                none++;
            list.forEach(function (n) {
                var k = n.toLowerCase();
                counts[k] = (counts[k] || 0) + 1;
                names[k] = names[k] || n;
            });
        });
        var chips = Object.keys(counts).sort().map(function (k) { return { key : k, name : names[k], count : counts[k] }; });
        var result = { chips : chips, none : none, all : $scope.bgSm.rows.filter(function (r) { return !r.deleted; }).length };
        // Same answer -> same objects, so ng-repeat's watch settles
        var sig = JSON.stringify(result);
        if (sig !== chipCache.sig)
            chipCache = { sig : sig, value : result };
        return chipCache.value;
    };
    var chipCache = { sig : null, value : null };

    /* Manage groups: every saved server group, empty ones too, with Delete */
    $scope.bgGm = { open : false, confirm : null, busy : false, error : null, done : null };

    $scope.bgSavedGroups = function bgSavedGroups() {
        return (groupState && groupState.groups) || [];
    };

    $scope.bgHasUnsaved = function bgHasUnsaved() {
        return $scope.bgSm.rows.some(function (r) { return r.deleted || $scope.bgIsChanged(r); })
            || !!(norm($scope.bgSm.blank && $scope.bgSm.blank.name) || norm($scope.bgSm.blank && $scope.bgSm.blank.hostname));
    };

    $scope.bgDeleteGroup = function bgDeleteGroup(group) {
        if ($scope.bgGm.busy)
            return;
        if ($scope.bgHasUnsaved()) {
            $scope.bgGm.error = 'Save or undo your changes to the list first, then delete the group.';
            return;
        }
        $scope.bgGm.busy = true;
        $scope.bgGm.error = null;
        bgServerGroups.remove(dataSource, group).then(function () {
            $scope.bgGm.confirm = null;
            $scope.bgGm.done = 'Deleted the group ' + group.name + '.';
            if ($scope.bgSm.filter.group === group.name.toLowerCase())
                $scope.bgSm.filter.group = null;
            load();
        }, function (err) {
            $scope.bgGm.error = "The group " + group.name + " couldn't be deleted"
                + (err && err.message ? ': ' + err.message : '.');
        }).finally(function () {
            $scope.bgGm.busy = false;
        });
    };

    $scope.bgSetGroupFilter = function bgSetGroupFilter(key) {
        $scope.bgSm.filter.group = ($scope.bgSm.filter.group === key) ? null : key;
    };

    $scope.bgVisible = function bgVisible(row) {
        var f = $scope.bgSm.filter;
        if (f.group === '__failed__') {
            if (!row.test || row.test.ok !== false)
                return false;
        }
        else if (f.group) {
            var keys = sgParse(row.groups).map(function (n) { return n.toLowerCase(); });
            if (f.group === '__none__' ? keys.length : keys.indexOf(f.group) === -1)
                return false;
        }
        var t = norm(f.text).toLowerCase();
        if (t) {
            var hay = [row.name, row.hostname, row.username, row.groups, row.protocol].join(' ').toLowerCase();
            if (hay.indexOf(t) === -1)
                return false;
        }
        return true;
    };


    /* Connection tests for rows in the list (uses what's typed, saved or not) */

    var testKey = function testKey(row) {
        return [row.protocol, norm(row.hostname), norm(row.port), row.protocol === 'ssh' ? norm(row.keyfile) : ''].join('|');
    };

    var runTests = function runTests(rows) {
        rows = rows.filter(function (r) { return !r.deleted && !(r.test && r.test.running); });
        var bad = rows.filter(function (r) { return smHostProblem(r.hostname) || !smValidPort(r.port); });
        bad.forEach(function (r) {
            r.test = { ok : false, detail : smHostProblem(r.hostname) || 'The port must be a number from 1 to 65535.', key : testKey(r) };
        });
        rows = rows.filter(function (r) { return bad.indexOf(r) === -1; });
        rows.forEach(function (r) { r.test = { running : true }; });
        var chunks = [];
        for (var i = 0; i < rows.length; i += 200)
            chunks.push(rows.slice(i, i + 200));
        return $q.all(chunks.map(function (chunk) {
            return bgConnectivity.check(dataSource, chunk.map(function (r) {
                return { host : r.hostname, port : r.port, protocol : r.protocol };
            })).then(function (results) {
                chunk.forEach(function (r, idx) {
                    var res = results[idx] || {};
                    var needsKey = r.protocol === 'ssh' && norm(r.keyfile) && !sshKeyPathProblem(r.keyfile);
                    r.test = { ok : !!res.ok, detail : res.detail || '', ms : res.ms, port : res.port, key : testKey(r), at : new Date(), running : !!needsKey };
                });
                var withKeys = chunk.filter(function (r) { return r.protocol === 'ssh' && norm(r.keyfile) && !sshKeyPathProblem(r.keyfile); });
                return bgSshKeys.check(dataSource, withKeys.map(function (r) { return norm(r.keyfile); })).then(function (keys) {
                    withKeys.forEach(function (r, idx) {
                        var k = keys[idx] || {};
                        r.test.keyDetail = k.detail || '';
                        r.test.running = false;
                        r.test.keyOk = !!k.ok;
                        if (!k.ok) {
                            r.test.ok = false;
                            r.test.detail = (r.test.detail ? r.test.detail + ' ' : '') + 'Key file: ' + (k.detail || 'not usable.');
                        }
                        else
                            r.test.detail = (r.test.detail ? r.test.detail + ' ' : '') + 'Key file: ' + k.detail;
                    });
                }, function () {
                    withKeys.forEach(function (r) { r.test.running = false; });
                });
            }, function (err) {
                chunk.forEach(function (r) {
                    r.test = { ok : null, detail : "The test couldn't run: " + errorText(err), key : testKey(r) };
                });
            });
        }));
    };

    $scope.bgTestRow = function bgTestRow(row) {
        runTests([row]);
    };

    $scope.bgTestAll = function bgTestAll() {
        $scope.bgSm.testingAll = true;
        runTests($scope.bgSm.rows.filter(function (r) { return !r.deleted && $scope.bgVisible(r); }))
        .finally(function () {
            $scope.bgSm.testingAll = false;
            if ($scope.bgFailedRows().length)
                openFailed();
        });
    };

    /* A result goes stale once the host, port or type is edited */
    $scope.bgTestState = function bgTestState(row) {
        var t = row.test;
        if (!t)
            return null;
        if (t.running)
            return 'running';
        if (t.key !== testKey(row))
            return 'stale';
        return t.ok === true ? 'ok' : (t.ok === false ? 'failed' : 'error');
    };

    var openFailed = function openFailed() {
        $scope.bgSm.failedOpen = true;
        setTimeout(function () {
            var m = $element[0].querySelector('.bg-sm-modal');
            if (m) m.focus();
        }, 0);
    };

    // Escape closes the popup wherever the focus is
    var onKey = function (e) {
        if (e.keyCode === 27 && $scope.bgSm.failedOpen)
            $scope.$apply(function () { $scope.bgSm.failedOpen = false; });
    };
    document.addEventListener('keydown', onKey);
    $scope.$on('$destroy', function () { document.removeEventListener('keydown', onKey); });

    $scope.bgFailedRows = function bgFailedRows() {
        return $scope.bgSm.rows.filter(function (r) {
            return !r.deleted && r.test && r.test.ok === false && !r.test.running;
        });
    };

    $scope.bgRetestFailed = function bgRetestFailed() {
        runTests($scope.bgFailedRows());
    };

    $scope.bgShowFailedOnly = function bgShowFailedOnly() {
        $scope.bgSm.filter.text = '';
        $scope.bgSm.filter.group = $scope.bgSm.filter.group === '__failed__' ? null : '__failed__';
    };

    $scope.bgFocusRow = function bgFocusRow(row) {
        $scope.bgSm.filter.text = '';
        if ($scope.bgSm.filter.group !== '__failed__')
            $scope.bgSm.filter.group = null;
        setTimeout(function () {
            var el = $element[0].querySelector('.bg-sm-row[data-key="' + row.key + '"]');
            if (el) {
                el.scrollIntoView({ block : 'center', behavior : 'smooth' });
                el.classList.add('bg-sm-flash');
                setTimeout(function () { el.classList.remove('bg-sm-flash'); }, 1600);
            }
        }, 0);
    };

    $scope.bgHiddenCount = function bgHiddenCount() {
        return $scope.bgSm.rows.filter(function (r) { return !$scope.bgVisible(r); }).length;
    };

    var pending = function pending() {
        var out = { add : [], update : [], remove : [] };
        $scope.bgSm.rows.forEach(function (row) {
            if (row.deleted) {
                if (!row.isNew)
                    out.remove.push(row);
            }
            else if (row.isNew)
                out.add.push(row);
            else if ($scope.bgIsChanged(row))
                out.update.push(row);
        });
        return out;
    };

    $scope.bgPendingCount = function bgPendingCount() {
        var p = pending();
        return p.add.length + p.update.length + p.remove.length;
    };

    $scope.bgSummary = function bgSummary() {
        var p = pending(), parts = [];
        if (p.add.length)    parts.push(p.add.length + ' to add');
        if (p.update.length) parts.push(p.update.length + ' changed');
        if (p.remove.length) parts.push(p.remove.length + ' to delete');
        return parts.length ? 'Not saved yet: ' + parts.join(', ') + '.' : 'No unsaved changes.';
    };

    /* Problems with one row, given the other rows' names */
    var rowProblems = function rowProblems(row, others) {
        var problems = [];
        var name = norm(row.name);
        if (!name)
            problems.push('Give the server a name.');
        else if (name.length > 128)
            problems.push('The name is too long.');
        else if (others.some(function (o) { return o !== row && !o.deleted && norm(o.name).toLowerCase() === name.toLowerCase(); }))
            problems.push('Another server already has this name.');
        if (SM_PROTOCOLS.indexOf(row.protocol) === -1 && !(row.original && row.original.protocol === row.protocol))
            problems.push('Choose a type.');
        var hostChanged = row.isNew || norm(row.hostname) !== norm(row.original.hostname);
        var hp = smHostProblem(row.hostname);
        if (hp && (hostChanged || norm(row.hostname)))
            problems.push(hp);
        if (!smValidPort(row.port))
            problems.push('The port must be a number from 1 to 65535.');
        var gp = sgProblem(sgParse(row.groups));
        if (gp)
            problems.push(gp);
        var kp = sshKeyPathProblem(row.keyfile);
        if (kp)
            problems.push(kp);
        else if (norm(row.keyfile) && row.protocol !== 'ssh')
            problems.push('A key file only works for SSH servers. Clear it or change the type to SSH.');
        else if (row.original && row.original.pastedKey && !norm(row.keyfile) && row.protocol === 'ssh' && connChanged(row))
            problems.push('This server still has a pasted key from before. Enter the path to its key file to save it.');
        return problems;
    };

    var load = function load() {
        $scope.bgSm.loaded = false;
        $scope.bgSm.loadError = null;
        bgServerGroups.load(dataSource).then(function (state) {
            groupState = state;
            return connectionGroupService.getConnectionGroupTree(dataSource, ConnectionGroup.ROOT_IDENTIFIER);
        }).then(function (root) {
            var found = [];
            var walk = function walk(group, path) {
                (group.childConnections || []).forEach(function (c) { found.push({ c : c, path : path }); });
                (group.childConnectionGroups || []).forEach(function (g) {
                    walk(g, path ? path + ' / ' + g.name : g.name);
                });
            };
            walk(root, '');
            return $q.all(found.map(function (f) {
                return connectionService.getConnectionParameters(dataSource, f.c.identifier).then(function (params) {
                    return { f : f, params : params || {} };
                }, function () { return { f : f, params : {} }; });
            }));
        }).then(function (items) {
            var rows = items.map(function (it) {
                var c = it.f.c, p = it.params;
                var original = {
                    name     : c.name || '',
                    protocol : c.protocol || '',
                    hostname : p.hostname || '',
                    port     : p.port || '',
                    username : p.username || '',
                    keyfile  : p['private-key-file'] || '',
                    pastedKey : !!(p['private-key'] && p['private-key'] !== SSH_KEY_PLACEHOLDER && !p['private-key-file']),
                    groups   : (groupState.byConnection[String(c.identifier)] || []).join(', ')
                };
                return angular.extend({
                    key        : 'r' + (++keySeq),
                    identifier : c.identifier,
                    parent     : c.parentIdentifier,
                    group      : it.f.path,
                    original   : original,
                    password   : '',
                    problems   : []
                }, angular.copy(original));
            });
            rows.sort(function (a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1; });
            rows.forEach(function (r) {
                if (r.protocol && SM_PROTOCOLS.indexOf(r.protocol) === -1
                        && !$scope.bgProtocols.some(function (p) { return p.value === r.protocol; }))
                    $scope.bgProtocols.push({ value : r.protocol, label : r.protocol });
            });
            $scope.bgSm.rows = rows;
            $scope.bgSm.groupNames = groupState.groups.map(function (g) { return g.name; });
            $scope.bgSm.loaded = true;
        }, function (err) {
            $scope.bgSm.loadError = "The server list couldn't be loaded" + (err && err.message ? ': ' + err.message : '.');
        });
    };
    load();

    // + : the filled-in blank row joins the list, and a new blank row opens
    $scope.bgAdd = function bgAdd() {
        var b = $scope.bgSm.blank;
        b.isNew = true;
        b.problems = rowProblems(b, $scope.bgSm.rows.concat([b]));
        if (b.problems.length)
            return;
        var row = {
            key      : 'r' + (++keySeq),
            isNew    : true,
            name     : norm(b.name),
            protocol : b.protocol,
            hostname : norm(b.hostname),
            port     : norm(b.port),
            username : norm(b.username),
            password : b.password || '',
            keyfile  : norm(b.keyfile),
            groups   : bgServerGroups.canonical(groupState, sgParse(b.groups)).join(', '),
            original : {},
            problems : []
        };
        $scope.bgSm.rows.push(row);
        var keepProtocol = b.protocol, keepGroups = row.groups;
        $scope.bgSm.blank = blankRow();
        $scope.bgSm.blank.protocol = keepProtocol;
        $scope.bgSm.blank.groups = keepGroups;
        $scope.bgSm.result = null;
        setTimeout(function () {
            var el = $element[0].querySelector('.bg-sm-blank .bg-sm-name');
            if (el) el.focus();
        }, 0);
    };

    // x : an unsaved row just goes; a saved server is marked until Save
    $scope.bgRemove = function bgRemove(row) {
        if (row.isNew) {
            var i = $scope.bgSm.rows.indexOf(row);
            if (i !== -1)
                $scope.bgSm.rows.splice(i, 1);
        }
        else
            row.deleted = true;
    };

    $scope.bgDiscard = function bgDiscard() {
        $scope.bgSm.result = null;
        $scope.bgSm.blank = blankRow();
        load();
    };

    var errorText = function errorText(err) {
        if (!err)
            return 'Unknown error.';
        if (err.message)
            return err.message;
        if (err.translatableMessage && err.translatableMessage.key)
            return err.translatableMessage.key;
        return String(err);
    };

    var buildParameters = function buildParameters(row, existing) {
        var params = angular.extend({}, existing || {});
        params.hostname = norm(row.hostname);
        if (norm(row.port)) params.port = norm(row.port); else delete params.port;
        if (norm(row.username)) params.username = norm(row.username); else delete params.username;
        if (row.password) params.password = row.password;
        if (!params.hostname) delete params.hostname;
        // SSH keys are a file path; the server fills in the key when someone connects
        if (row.protocol === 'ssh' && norm(row.keyfile)) {
            params['private-key-file'] = norm(row.keyfile);
            params['private-key'] = SSH_KEY_PLACEHOLDER;
        }
        else {
            delete params['private-key-file'];
            if (params['private-key'] === SSH_KEY_PLACEHOLDER)
                delete params['private-key'];
        }
        return params;
    };

    var doSave = function doSave(p) {
        $scope.bgSm.saving = true;
        $scope.bgSm.result = null;
        var failures = 0, done = { add : 0, update : 0, remove : 0 };

        var fail = function (row, err) {
            failures++;
            row.status = 'failed';
            row.statusText = "Couldn't save: " + errorText(err);
        };

        // Deletes first (frees names), then changes, then new servers
        var removals = $q.all(p.remove.map(function (row) {
            return connectionService.deleteConnection(dataSource, { identifier : row.identifier }).then(function () {
                done.remove++;
                row.gone = true;
            }, function (err) { fail(row, err); });
        }));

        return removals.then(function () {
            return $q.all(p.update.map(function (row) {
                var step = !connChanged(row) ? $q.when() : $q.all([
                    connectionService.getConnection(dataSource, row.identifier),
                    connectionService.getConnectionParameters(dataSource, row.identifier)
                ]).then(function (got) {
                    var c = angular.copy(got[0]);
                    c.name = norm(row.name);
                    c.protocol = row.protocol;
                    c.parameters = buildParameters(row, got[1]);
                    return connectionService.saveConnection(dataSource, c);
                });
                return step.then(function () {
                    if (groupsChanged(row))
                        return bgServerGroups.setServerGroups(dataSource, groupState, row.identifier, sgParse(row.groups));
                }).then(function () {
                    done.update++;
                    row.status = 'saved';
                }, function (err) { fail(row, err); });
            }));
        }).then(function () {
            return $q.all(p.add.map(function (row) {
                var c = new Connection({
                    name             : norm(row.name),
                    protocol         : row.protocol,
                    parentIdentifier : ConnectionGroup.ROOT_IDENTIFIER,
                    parameters       : buildParameters(row, {}),
                    attributes       : {}
                });
                return connectionService.saveConnection(dataSource, c).then(function () {
                    row.isNew = false;
                    row.identifier = c.identifier;
                    row.original = { groups : '' };
                    var names = sgParse(row.groups);
                    if (names.length)
                        return bgServerGroups.setServerGroups(dataSource, groupState, c.identifier, names);
                }).then(function () {
                    done.add++;
                    row.status = 'saved';
                }, function (err) { fail(row, err); });
            }));
        }).then(function () {
            var parts = [];
            if (done.add)    parts.push(done.add + ' added');
            if (done.update) parts.push(done.update + ' updated');
            if (done.remove) parts.push(done.remove + ' deleted');
            var text = parts.length ? 'Saved: ' + parts.join(', ') + '.' : '';
            if (!failures) {
                // Reload the page so the groups view and home list match too
                smLastResult = { text : text || 'Saved.', bad : false };
                $route.reload();
                return;
            }
            $scope.bgSm.saving = false;
            $scope.bgSm.rows = $scope.bgSm.rows.filter(function (r) { return !r.gone; });
            $scope.bgSm.rows.forEach(function (r) {
                if (r.status === 'saved') {
                    r.original = { name : norm(r.name), protocol : r.protocol, hostname : norm(r.hostname), port : norm(r.port), username : norm(r.username), keyfile : norm(r.keyfile), groups : r.groups };
                    r.password = '';
                }
            });
            $scope.bgSm.result = (text ? text + ' ' : '') + failures + (failures === 1 ? " change wasn't" : " changes weren't")
                + ' saved. The rows marked in red say why.';
            $scope.bgSm.resultBad = true;
        });
    };

    $scope.bgSave = function bgSave() {
        var rows = $scope.bgSm.rows;
        var bad = 0;
        rows.forEach(function (row) {
            row.status = null;
            row.statusText = null;
            row.problems = (row.deleted || !$scope.bgIsChanged(row)) ? [] : rowProblems(row, rows);
            if (row.problems.length) bad++;
        });
        if (bad) {
            $scope.bgSm.result = bad === 1 ? 'One row needs fixing before saving.' : bad + ' rows need fixing before saving.';
            $scope.bgSm.resultBad = true;
            return;
        }
        var p = pending();
        if (!p.remove.length) {
            doSave(p);
            return;
        }
        guacNotification.showStatus({
            title   : 'BETTERGUAC.DIALOG_HEADER_DELETE_SERVERS',
            text    : { key : 'BETTERGUAC.TEXT_DELETE_SERVERS', variables : {
                NAMES : p.remove.map(function (r) { return r.original.name; }).join(', ')
            } },
            actions : [{
                name      : 'BETTERGUAC.ACTION_DELETE_AND_SAVE',
                className : 'danger',
                callback  : function () { guacNotification.showStatus(false); doSave(p); }
            }, {
                name      : 'BETTERGUAC.ACTION_CANCEL',
                className : 'cancel',
                callback  : function () { guacNotification.showStatus(false); }
            }]
        });
    };

    /* Bulk editor */

    var parseType = function parseType(t) {
        t = norm(t).toLowerCase();
        t = SM_ALIASES[t] || t;
        return SM_PROTOCOLS.indexOf(t) !== -1 ? t : null;
    };

    $scope.bgCheckBulk = function bgCheckBulk() {
        var lines = String($scope.bgSm.bulkText || '').split(/\r?\n/);
        var out = [], seen = {}, first = true;
        lines.forEach(function (raw, idx) {
            var text = raw.trim();
            if (!text || text.charAt(0) === '#')
                return;
            var cells = (text.indexOf('\t') !== -1 ? text.split('\t') : text.split(',')).map(norm);
            if (first && cells[0].toLowerCase() === 'name') {
                first = false;
                return;
            }
            first = false;
            var b = {
                line     : idx + 1,
                raw      : raw,
                name     : cells[0] || '',
                typeText : cells[1] || '',
                protocol : parseType(cells[1]),
                hostname : '',
                port     : '',
                username : cells[4] || '',
                keyfile  : '',
                groups   : '',
                errors   : []
            };
            // Key file: the 6th column, when it's a path (starts with /) or
            // pasted key text. Groups come after it. Lines from before key
            // files (6th column = groups) still read the same.
            // Comma lines: every column after that is a group. Tab lines:
            // groups in one cell, split by , or ;
            var tabbed = text.indexOf('\t') !== -1;
            var sixth = cells[5] || '';
            var hasKeyCol = sixth.charAt(0) === '/' || sixth.charAt(0) === '~' || sixth.indexOf('-----BEGIN') !== -1
                    || (tabbed && cells.length >= 7);
            if (hasKeyCol)
                b.keyfile = sixth;
            var gStart = hasKeyCol ? 6 : 5;
            var groupCells = tabbed ? cells.slice(gStart, gStart + 1) : cells.slice(gStart);
            b.groups = sgParse(groupCells.join(',')).join(', ');
            b.protocolLabel = b.protocol ? (PROTOCOL_LABELS[b.protocol] || b.protocol) : b.typeText;
            var split = smSplitHost(cells[2] || '');
            b.hostname = split.host;
            var portCell = cells[3] || '';
            if (split.port && portCell && split.port !== portCell)
                b.errors.push('Two different ports (' + split.port + ' and ' + portCell + ').');
            b.port = portCell || split.port;

            if (tabbed && cells.length > 7)
                b.errors.push('Too many columns (' + cells.length + '). Expected name, type, host, port, username, key file, groups.');
            else if (cells.length < 3)
                b.errors.push('Needs at least a name, a type and a host.');
            else {
                if (!b.name)
                    b.errors.push('The name is missing.');
                if (!b.protocol)
                    b.errors.push(b.typeText ? 'Unknown type "' + b.typeText + '". Use ssh, rdp, vnc, telnet or kubernetes.' : 'The type is missing.');
                var hp = smHostProblem(b.hostname);
                if (hp) b.errors.push(hp);
                if (!smValidPort(b.port))
                    b.errors.push('The port must be a number from 1 to 65535.');
                var gp = sgProblem(sgParse(b.groups));
                if (gp) b.errors.push(gp);
                var kp = sshKeyPathProblem(b.keyfile);
                if (kp) b.errors.push(kp);
                else if (b.keyfile && b.protocol && b.protocol !== 'ssh')
                    b.errors.push('A key file only works for SSH servers.');
            }
            if (b.name) {
                var lower = b.name.toLowerCase();
                if (seen[lower])
                    b.errors.push('The same name is already on line ' + seen[lower] + '.');
                else
                    seen[lower] = b.line;
                var match = $scope.bgSm.rows.filter(function (r) { return norm(r.name).toLowerCase() === lower; })[0];
                if (match && match.deleted)
                    b.errors.push('This server is marked for deletion above. Press Undo there first.');
                else if (match)
                    b.target = match;
            }
            out.push(b);
        });
        $scope.bgSm.bulk = out;
        var good = out.filter(function (b) { return !b.errors.length; });
        good.forEach(function (b) { b.test = { running : true }; });
        $scope.bgSm.bulkTesting = !!good.length;
        var chunks = [];
        for (var c = 0; c < good.length; c += 200)
            chunks.push(good.slice(c, c + 200));
        $q.all(chunks.map(function (chunk) {
            return bgConnectivity.check(dataSource, chunk.map(function (b) {
                return { host : b.hostname, port : b.port, protocol : b.protocol };
            })).then(function (results) {
                chunk.forEach(function (b, i) {
                    var res = results[i] || {};
                    b.test = { ok : !!res.ok, detail : res.detail || '', port : res.port, running : !!b.keyfile };
                });
                var withKeys = chunk.filter(function (b) { return b.keyfile; });
                return bgSshKeys.check(dataSource, withKeys.map(function (b) { return b.keyfile; })).then(function (keys) {
                    withKeys.forEach(function (b, i) {
                        var k = keys[i] || {};
                        b.keyCheck = { ok : !!k.ok, detail : k.detail || '' };
                        b.test.running = false;
                        if (!k.ok)
                            b.test.ok = false;
                        b.test.detail = (b.test.detail ? b.test.detail + ' ' : '') + 'Key file: ' + (k.detail || 'not usable.');
                    });
                }, function () {
                    withKeys.forEach(function (b) { b.test.running = false; });
                });
            }, function (err) {
                chunk.forEach(function (b) { b.test = { ok : null, detail : "The test couldn't run: " + errorText(err) }; });
            });
        })).finally(function () {
            if ($scope.bgSm.bulk !== out)
                return;
            $scope.bgSm.bulkTesting = false;
            var unreachable = good.filter(function (b) { return b.test && b.test.ok === false; }).length;
            if (unreachable)
                $scope.bgSm.bulkMessage += ' ' + unreachable + (unreachable === 1 ? " server didn't answer" : " servers didn't answer")
                    + ' from the BetterGuac server. You can still apply ' + (unreachable === 1 ? 'it' : 'them') + '.';
        });
        var bad = out.filter(function (b) { return b.errors.length; }).length;
        $scope.bgSm.bulkMessage = !out.length ? 'There are no server lines to check.'
            : (out.length - bad) + ' of ' + out.length + (out.length === 1 ? ' line is' : ' lines are') + ' ready'
              + (bad ? ', ' + bad + ' need fixing.' : '.');
    };

    $scope.bgBulkValidCount = function bgBulkValidCount() {
        return ($scope.bgSm.bulk || []).filter(function (b) { return !b.errors.length; }).length;
    };

    $scope.bgApplyBulk = function bgApplyBulk() {
        var added = 0, updated = 0, kept = [];
        ($scope.bgSm.bulk || []).forEach(function (b) {
            if (b.errors.length) {
                kept.push(b.raw);
                return;
            }
            if (b.target) {
                b.target.protocol = b.protocol;
                b.target.hostname = b.hostname;
                if (b.port) b.target.port = b.port;
                if (b.username) b.target.username = b.username;
                if (b.keyfile) b.target.keyfile = b.keyfile;
                if (b.groups) b.target.groups = bgServerGroups.canonical(groupState, sgParse(b.groups)).join(', ');
                b.target.problems = [];
                if (b.test && !b.test.running && b.test.ok !== null)
                    b.target.test = angular.extend({}, b.test, { key : testKey(b.target) });
                updated++;
            }
            else {
                $scope.bgSm.rows.push({
                    key      : 'r' + (++keySeq),
                    isNew    : true,
                    name     : b.name,
                    protocol : b.protocol,
                    hostname : b.hostname,
                    port     : b.port,
                    username : b.username,
                    keyfile  : b.keyfile,
                    password : '',
                    groups   : bgServerGroups.canonical(groupState, sgParse(b.groups)).join(', '),
                    original : {},
                    problems : []
                });
                var added_row = $scope.bgSm.rows[$scope.bgSm.rows.length - 1];
                if (b.test && !b.test.running && b.test.ok !== null)
                    added_row.test = angular.extend({}, b.test, { key : testKey(added_row) });
                added++;
            }
        });
        $scope.bgSm.bulkText = kept.join('\n');
        $scope.bgSm.bulk = null;
        var parts = [];
        if (added)   parts.push(added + ' new');
        if (updated) parts.push(updated + ' updated');
        $scope.bgSm.bulkMessage = 'Put ' + parts.join(' and ') + ' in the list above. Press Save changes to keep them.'
            + (kept.length ? ' ' + kept.length + (kept.length === 1 ? ' line with a problem stayed' : ' lines with problems stayed') + ' in the box.' : '');
        $scope.bgSm.result = null;
    };

}]);


/* ---------------------------------------------------------------------
 * "?" help: a round button that opens a short explanation panel
 * ------------------------------------------------------------------- */

/* ---------------------------------------------------------------------
 * One-line navigation: replaces Guacamole's user drop-down menu on every
 * page. Home, Servers and Users (admins), My profile, the person's picture
 * and name, and Log out, all in one row.
 * ------------------------------------------------------------------- */

angular.module('index').directive('bgNav', ['$injector', function bgNav($injector) {

    var $location             = $injector.get('$location');
    var authenticationService = $injector.get('authenticationService');
    var bgSession             = $injector.get('bgSession');

    return {
        restrict : 'E',
        scope    : {},
        template : '<nav class="bg-nav" ng-show="signedIn()" aria-label="BetterGuac">'
                 +   '<a class="bg-nav-item" ng-repeat="item in items()" ng-href="{{ item.href }}" '
                 +      'ng-class="{ \'bg-nav-active\' : item.active() }" data-nav="{{ item.key }}">{{ item.label }}</a>'
                 +   '<a class="bg-nav-user" href="#/settings/preferences" title="{{ username() }}">'
                 +     '<span class="bg-avatar bg-avatar-sm">'
                 +       '<img ng-if="avatar()" ng-src="{{ avatar() }}" alt="">'
                 +       '<span ng-if="!avatar()">{{ initials() }}</span>'
                 +     '</span>'
                 +     '<span class="bg-nav-name">{{ name() }}</span>'
                 +   '</a>'
                 +   '<button type="button" class="bg-nav-logout" data-nav="logout" ng-click="logout()">Log out</button>'
                 + '</nav>',
        link : function bgNavLink(scope) {

            scope.signedIn = function signedIn() {
                return !!authenticationService.getCurrentToken() && !authenticationService.isAnonymous();
            };

            var path = function path() { return $location.path() || '/'; };

            var HOME = { key : 'home', label : 'Home', href : '#/',
                         active : function () { return path() === '/'; } };
            var PROFILE = { key : 'profile', label : 'My profile', href : '#/settings/preferences',
                            active : function () { return /\/settings\/preferences$/.test(path()); } };
            var cache = { ds : null, list : null };

            scope.items = function items() {
                var ds = bgSession.dataSource();
                var admin = bgSession.adminNow() === true;
                var key = ds + ':' + admin;
                if (cache.key === key)
                    return cache.list;
                var list = [HOME];
                if (admin) {
                    list.push({ key : 'servers', label : 'Servers',
                                href : '#/settings/' + encodeURIComponent(ds) + '/connections',
                                active : function () { return /\/settings\/[^\/]+\/connections$/.test(path())
                                    || /^\/manage\/[^\/]+\/connections/.test(path()); } });
                    list.push({ key : 'users', label : 'Users', href : '#/settings/users',
                                active : function () { return /\/settings\/users$/.test(path())
                                    || /^\/manage\/[^\/]+\/users/.test(path()); } });
                }
                list.push(PROFILE);
                cache = { key : key, list : list };
                return list;
            };

            scope.username = function username() { return authenticationService.getCurrentUsername(); };
            scope.name = function name() {
                return displayNameOf(bgSession.selfNow()) || scope.username();
            };
            scope.avatar = function avatar() {
                var u = bgSession.selfNow();
                return (u && u.attributes && u.attributes['bg-avatar']) || null;
            };
            scope.initials = function initials() {
                return initialsOf(bgSession.selfNow() || { username : scope.username() });
            };

            // Same as Guacamole's own "Logout" menu item
            scope.logout = function logout() {
                authenticationService.logout()['catch'](angular.noop);
            };
        }
    };
}]);

angular.module('index').directive('bgHelp', [function bgHelp() {
    return {
        restrict   : 'E',
        transclude : true,
        scope      : { label : '@' },
        template   : '<div class="bg-help">'
                   +   '<button type="button" class="bg-help-btn" ng-click="open = !open" '
                   +     'aria-expanded="{{ !!open }}" title="{{ label }}" aria-label="{{ label }}">?</button>'
                   +   '<div class="bg-help-panel" ng-show="open" ng-transclude></div>'
                   + '</div>'
    };
}]);

})();
