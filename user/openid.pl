/*  $Id$

    Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        wielemak@science.uva.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2007, University of Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

:- module(cliopatria_openid,
	  [ openid_for_local_user/2
	  ]).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_wrapper)).
:- use_module(library(http/http_openid)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/http_session)).
:- use_module(library(http/html_write)).
:- use_module(library(http/html_head)).
:- use_module(library(http/http_hook)).
:- use_module(library(lists)).
:- use_module(library(error)).
:- use_module(library(option)).
:- use_module(library(uri)).
:- use_module(library(socket)).
:- use_module(library(debug)).
:- use_module(library(settings)).
:- use_module(user_db).


/** <module> OpenID server and client access

This module customizes login and OpenID handling for ClioPatria.

@author	Jan Wielemaker
*/

http:location(openid, root(openid), []).

		 /*******************************
		 *	CUSTOMISE OPENID	*
		 *******************************/

:- http_handler(openid(grant),  openid_grant, [prefix]).

:- multifile
	http_openid:openid_hook/1.

http_openid:openid_hook(login(OpenID)) :-
	login(OpenID).
http_openid:openid_hook(logout(OpenID)) :-
	logout(OpenID).
http_openid:openid_hook(logged_in(OpenID)) :-
	logged_on(OpenID).
http_openid:openid_hook(trusted(OpenID, Server)) :-
	(   openid_server_properties(Server, _)
	->  true
	;   format(string(Msg), 'OpenID server ~w is not trusted', [Server]),
	    throw(error(permission_error(login, openid, OpenID),
			context(_, Msg)))
	).


:- http_handler(openid(login), login_page, [priority(10)]).

:- multifile insecure_host/1.

%%	login_page(+Request)
%
%	HTTP Handler that shows both OpenID   login and local login-page
%	to the user. This handler overrules the default OpenID handler.

login_page(Request) :-
   debug(openid,'Got login request: ~q',[Request]),
   (  member(x_forwarded_host(Host),Request),
      member(protocol(http),Request),
      insecure_host(Host)
   -> reply_html_page(cliopatria(default), title('Login'),
                      [ p('Login from public website ~w over insecure connection disabled.'-Host) ])
   ;  \+member(x_forwarded_host(_),Request),
      member(protocol(http),Request), 
      thread_httpd:http_server_property(SSLPort,goal(conf_https:http_dispatch))
   -> member(path(Path),Request),
      member(search(Search),Request),
      member(host(Host),Request),
      parse_url(NewURL,[protocol(https),port(SSLPort),host(Host),path(Path),search(Search)]),
      debug(openid,'Going to redirect to ~w',[NewURL]),
      http_redirect(moved_temporary,NewURL,Request)
   ;  http_open_session(_, []),		% we need sessions to login
      http_parameters(Request,
            [ 'openid.return_to'(ReturnTo,
                       [ description('Page to visit after login')
                       ])
            ]),
      reply_html_page(cliopatria(default),
            title('Login'),
            [ \explain_login(ReturnTo),
              \maybe_insecure_login_warning(Request),
              \cond_openid_login_form(ReturnTo),
              \local_login(ReturnTo)
            ])
   ).

maybe_insecure_login_warning(Request) -->
   (   {member(protocol(https),Request)} -> []
   ;  html(p(style("color:#a00"),b('This is an unencrypted connection and the password will be sent as clear text.')))
   ).
% extracted from hacked http_openid
   % option(request_uri(RequestURI), Request),
   % http_public_host(Request, Host, Port, [ global(false) ]),
   % setting(http:public_scheme, Scheme),
   % (   scheme_port(Scheme, Port)
   % ->  format(atom(HostURL), '~w://~w', [Scheme, Host])
   % ;   format(atom(HostURL), '~w://~w:~w', [Scheme, Host, Port])
   % ),
   % atomic_list_concat([HostURL, RequestURI], URL).


explain_login(ReturnTo) -->
	{ uri_components(ReturnTo, Components),
	  uri_data(path, Components, Path)
	},
	html(div(class('rdfql-login'),
		 [ p([ 'You are trying to access a page (~w) that requires authorization. '-[Path],
		       \explain_open_id_login
		     ])
		 ])).

explain_open_id_login -->
	{ \+ openid_current_server(_) }, !.
explain_open_id_login -->
	html([ 'You can login either as a local user',
	       ' or with your ', a(href('http://www.openid.net'), 'OpenID'), '.']),
	(   { openid_current_server(*) }
	->  []
	;   { http_link_to_id(trusted_openid_servers, [], HREF) },
	    html([ ' from one of our ', a(href(HREF), 'trusted providers')])
	).

cond_openid_login_form(_) -->
	{ \+ openid_current_server(_) }, !.
cond_openid_login_form(ReturnTo) -->
	openid_login_form(ReturnTo, []).


local_login(ReturnTo) -->
	html(div(class('local-login'),
		 [ div(class('local-message'),
		       'Login with your local username and password'),
		   form([ action(location_by_id(user_login)),
			  method('GET')
			],
			[ \hidden('openid.return_to', ReturnTo),
			  div(input([name(user), size(20), type(text)])),
			  div([ input([name(password), size(20), type(password)]),
				input([type(submit), value('login')])
			      ])
			])
		 ])).

hidden(Name, Value) -->
	html(input([type(hidden), name(Name), value(Value)])).


:- http_handler(openid(list_trusted_servers), trusted_openid_servers, []).

%%	trusted_openid_servers(+Request)
%
%	HTTP handler to emit a list of OpenID servers we trust.

trusted_openid_servers(_Request) :-
	findall(S, openid_current_server(S), Servers),
	reply_html_page(cliopatria(default),
			title('Trusted OpenID servers'),
			[ h4('Trusted OpenID servers'),
			  p([ 'We accept OpenID logins from the following OpenID providers. ',
			      'Please register with one of them.'
			    ]),
			  ul(\trusted_openid_servers(Servers))
			]).

trusted_openid_servers([]) -->
	[].
trusted_openid_servers([H|T]) -->
	trusted_openid_server(H),
	trusted_openid_servers(T).

trusted_openid_server(*) --> !.
trusted_openid_server(URL) -->
	html(li(a(href(URL), URL))).


		 /*******************************
		 *	   OPENID SERVER	*
		 *******************************/

:- http_handler(root(user), openid_userpage, [prefix]).
:- http_handler(openid(server), openid_server([]), [prefix]).

http_openid:openid_hook(grant(Request, Options)) :-
	(   option(identity(Identity), Options),
	    option(password(Password), Options),
	    file_base_name(Identity, User),
	    validate_password(User, Password)
	->  option(trustroot(TrustRoot), Options),
	    debug(openid, 'Granted access for ~w to ~w', [Identity, TrustRoot])
	;   memberchk(path(Path), Request),
	    throw(error(permission_error(http_location, access, Path),
			context(_, 'Wrong password')))
	).


%%	openid_userpage(+Request)
%
%	Server user page for a registered user

openid_userpage(Request) :-
	memberchk(path(Path), Request),
	atomic_list_concat(Parts, /, Path),
	append(_, [user, User], Parts), !,
	file_base_name(Path, User),
	(   current_user(User)
	->  findall(P, user_property(User, P), Props),
	    reply_html_page(cliopatria(default),
			    [ link([ rel('openid.server'),
				     href(location_by_id(openid_server))
				   ]),
			      title('OpenID page for user ~w'-[User])
			    ],
			    [ h1('OpenID page for user ~w'-[User]),
			      \user_properties(Props)
			    ])
	;   existence_error(http_location, Path)
	).


user_properties([]) -->
	[].
user_properties([H|T]) -->
	user_property(H),
	user_properties(T).

user_property(realname(Name)) --> !,
	html(div(['Real name: ', Name])).
user_property(connection(Login, IdleF)) --> !,
	{ format_time(string(S), '%+', Login),
	  Idle is round(IdleF),
	  Hours is Idle // 3600,
	  Min is Idle mod 3600 // 60,
	  Sec is Idle mod 60
	},
	html(div(['Logged in since ~s, idle for ~d:~d:~d'-
		  [S, Hours,Min,Sec]])).
user_property(_) -->
	[].


%%	openid_for_local_user(+User, -URL) is semidet.
%
%	URL is the OpenID for the local user User.

openid_for_local_user(User, URL) :-
	http_current_request(Request),
	openid_current_host(Request, Host, Port),
	http_location_by_id(openid_userpage, UserPages),
	(   Port == 80
	->  format(atom(URL), 'http://~w~w/~w',
		   [ Host, UserPages, User ])
	;   format(atom(URL), 'http://~w:~w~w/~w',
		   [ Host, Port, UserPages, User ])
	).



		 /*******************************
		 *	       TEST		*
		 *******************************/

:- http_handler(cliopatria('user/form/login'), login_handler, [priority(10)]).

login_handler(_Request) :-
	ensure_logged_on(User),
	user_property(User, url(URL)),
	reply_html_page(cliopatria(default),
			title('Login ok'),
			[ h1('Login ok'),
			  p(['You''re logged on with OpenID ',
			     a(href(URL), URL)])
			]).
