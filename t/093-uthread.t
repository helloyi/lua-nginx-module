# vim:set ft= ts=4 sw=4 et fdm=marker:

use lib 'lib';
use Test::Nginx::Socket;

repeat_each(2);

plan tests => repeat_each() * (blocks() * 4);

$ENV{TEST_NGINX_RESOLVER} ||= '8.8.8.8';

our $GCScript = <<'_EOC_';
global ids, cur
global in_req = 0

function gen_id(k) {
    if (ids[k]) return ids[k]
    ids[k] = ++cur
    return cur
}

F(ngx_http_init_request) {
    in_req++
    if (in_req == 1) {
        delete ids
        cur = 0
    }
}

F(ngx_http_free_request) {
    in_req--
}

M(http-lua-user-thread-create) {
    p = gen_id($arg2)
    c = gen_id($arg3)
    printf("create user thread %x in %x\n", c, p)
}

M(http-lua-thread-delete) {
    t = gen_id($arg2)
    printf("delete thread %x\n", t)
}

_EOC_

our $StapScript = <<'_EOC_';
global ids, cur
global timers
global in_req = 0

function gen_id(k) {
    if (ids[k]) return ids[k]
    ids[k] = ++cur
    return cur
}

F(ngx_http_init_request) {
    in_req++
    if (in_req == 1) {
        delete ids
        cur = 0
    }
}

F(ngx_http_free_request) {
    in_req--
}

F(ngx_http_lua_co_cleanup) {
    id = gen_id(@cast($data, "ngx_http_lua_co_ctx_t")->co)
    printf("co cleanup called for thread %d\n", id)
}

M(timer-add) {
    timers[$arg1] = $arg2
    printf("add timer %d\n", $arg2)
}

M(timer-del) {
    printf("delete timer %d\n", timers[$arg1])
}

M(timer-expire) {
    printf("expire timer %d\n", timers[$arg1])
}

F(ngx_http_lua_sleep_handler) {
    printf("sleep handler called\n")
}

F(ngx_http_lua_run_thread) {
    id = gen_id($ctx->cur_co_ctx->co)
    printf("run thread %d\n", id)
    #if (id == 1) {
        #print_ubacktrace()
    #}
}

/*
probe process("/usr/local/openresty-debug/luajit/lib/libluajit-5.1.so.2").function("lua_resume") {
    id = gen_id($L)
    printf("lua resume %d\n", id)
}
*/

M(http-lua-user-thread-create) {
    p = gen_id($arg2)
    c = gen_id($arg3)
    printf("create uthread %x in %x\n", c, p)
}

M(http-lua-thread-delete) {
    t = gen_id($arg2)
    printf("delete thread %x\n", t)
}

M(http-lua-user-coroutine-resume) {
    p = gen_id($arg2)
    c = gen_id($arg3)
    printf("resume %x in %x\n", c, p)
}

M(http-lua-thread-yield) {
    println("thread yield")
}

/*
F(ngx_http_lua_coroutine_yield) {
    printf("yield %x\n", gen_id($L))
}
*/

M(http-lua-user-coroutine-yield) {
    p = gen_id($arg2)
    c = gen_id($arg3)
    printf("yield %x in %x\n", c, p)
}

F(ngx_http_lua_atpanic) {
    printf("lua atpanic(%d):", gen_id($L))
    print_ubacktrace();
}

F(ngx_http_lua_run_posted_threads) {
    printf("run posted threads\n")
}

F(ngx_http_finalize_request) {
    printf("finalize request: rc:%d c:%d\n", $rc, $r->main->count);
}

M(http-lua-user-coroutine-create) {
    p = gen_id($arg2)
    c = gen_id($arg3)
    printf("create %x in %x\n", c, p)
}

F(ngx_http_lua_ngx_exec) { println("exec") }

F(ngx_http_lua_ngx_exit) { println("exit") }
_EOC_

#no_shuffle();
no_long_string();
run_tests();

__DATA__

=== TEST 1: simple user thread without I/O
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.say("hello in thread")
            end

            ngx.say("before")
            ngx.thread.create(f)
            ngx.say("after")
        ';
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
delete thread 2
delete thread 1

--- response_body
before
hello in thread
after
--- no_error_log
[error]



=== TEST 2: two simple user threads without I/O
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.say("in thread 1")
            end

            function g()
                ngx.say("in thread 2")
            end

            ngx.say("before 1")
            ngx.thread.create(f)
            ngx.say("after 1")

            ngx.say("before 2")
            ngx.thread.create(g)
            ngx.say("after 2")
        ';
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
delete thread 2
create user thread 3 in 1
delete thread 3
delete thread 1

--- response_body
before 1
in thread 1
after 1
before 2
in thread 2
after 2
--- no_error_log
[error]



=== TEST 3: simple user thread with sleep
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.say("before sleep")
                ngx.sleep(0.1)
                ngx.say("after sleep")
            end

            ngx.say("before thread create")
            ngx.thread.create(f)
            ngx.say("after thread create")
        ';
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
delete thread 1
delete thread 2

--- response_body
before thread create
before sleep
after thread create
after sleep
--- no_error_log
[error]



=== TEST 4: two simple user threads with sleep
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.say("1: before sleep")
                ngx.sleep(0.2)
                ngx.say("1: after sleep")
            end

            function g()
                ngx.say("2: before sleep")
                ngx.sleep(0.1)
                ngx.say("2: after sleep")
            end

            ngx.say("1: before thread create")
            ngx.thread.create(f)
            ngx.say("1: after thread create")

            ngx.say("2: before thread create")
            ngx.thread.create(g)
            ngx.say("2: after thread create")
        ';
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
create user thread 3 in 1
delete thread 1
delete thread 3
delete thread 2

--- response_body
1: before thread create
1: before sleep
1: after thread create
2: before thread create
2: before sleep
2: after thread create
2: after sleep
1: after sleep
--- no_error_log
[error]



=== TEST 5: exit in user thread (entry still pending)
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.say("hello in thread")
                ngx.exit(0)
            end

            ngx.say("before")
            ngx.thread.create(f)
            ngx.say("after")
            ngx.sleep(1)
            ngx.say("end")
        ';
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
delete thread 2
delete thread 1

--- response_body
before
hello in thread
--- no_error_log
[error]



=== TEST 6: exit in user thread (entry already quits)
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.sleep(0.1)
                ngx.say("exiting the user thread")
                ngx.exit(0)
            end

            ngx.say("before")
            ngx.thread.create(f)
            ngx.say("after")
        ';
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
delete thread 1
delete thread 2

--- response_body
before
after
exiting the user thread
--- no_error_log
[error]



=== TEST 7: exec in user thread (entry still pending)
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.exec("/foo")
            end

            ngx.thread.create(f)
            ngx.sleep(1)
            ngx.say("hello")
        ';
    }

    location /foo {
        echo i am foo;
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
delete thread 2
delete thread 1

--- response_body
i am foo
--- no_error_log
[error]



=== TEST 8: exec in user thread (entry already quits)
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.sleep(0.1)
                ngx.exec("/foo")
            end

            ngx.thread.create(f)
        ';
    }

    location /foo {
        echo i am foo;
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
delete thread 1
delete thread 2

--- response_body
i am foo
--- no_error_log
[error]



=== TEST 9: error in user thread
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.blah()
            end

            ngx.thread.create(f)
            ngx.say("after")
        ';
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
delete thread 2
delete thread 1

--- response_body_like: 500 Internal Server Error
--- error_code: 500
--- error_log
lua thread aborted: runtime error: [string "content_by_lua"]:3: attempt to call field 'blah' (a nil value)



=== TEST 10: simple user threads doing a single subrequest (entry quits early)
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.say("before capture")
                res = ngx.location.capture("/proxy")
                ngx.say("after capture: ", res.body)
            end

            ngx.say("before thread create")
            ngx.thread.create(f)
            ngx.say("after thread create")
        ';
    }

    location /proxy {
        proxy_pass http://127.0.0.1:$server_port/foo;
    }

    location /foo {
        echo_sleep 0.1;
        echo -n hello world;
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
delete thread 1
delete thread 2

--- response_body
before thread create
before capture
after thread create
after capture: hello world
--- no_error_log
[error]



=== TEST 11: simple user threads doing a single subrequest (entry also does a subrequest and quits early)
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.say("before capture")
                local res = ngx.location.capture("/proxy?foo")
                ngx.say("after capture: ", res.body)
            end

            ngx.say("before thread create")
            ngx.thread.create(f)
            ngx.say("after thread create")
            local res = ngx.location.capture("/proxy?bar")
            ngx.say("capture: ", res.body)
        ';
    }

    location /proxy {
        proxy_pass http://127.0.0.1:$server_port/$args;
    }

    location /foo {
        echo_sleep 0.1;
        echo -n hello foo;
    }

    location /bar {
        echo -n hello bar;
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
delete thread 1
delete thread 2

--- response_body
before thread create
before capture
after thread create
capture: hello bar
after capture: hello foo
--- no_error_log
[error]



=== TEST 12: simple user threads doing a single subrequest (entry also does a subrequest and quits late)
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.say("before capture")
                local res = ngx.location.capture("/proxy?foo")
                ngx.say("after capture: ", res.body)
            end

            ngx.say("before thread create")
            ngx.thread.create(f)
            ngx.say("after thread create")
            local res = ngx.location.capture("/proxy?bar")
            ngx.say("capture: ", res.body)
        ';
    }

    location /proxy {
        proxy_pass http://127.0.0.1:$server_port/$args;
    }

    location /foo {
        echo_sleep 0.1;
        echo -n hello foo;
    }

    location /bar {
        echo_sleep 0.2;
        echo -n hello bar;
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
delete thread 2
delete thread 1

--- response_body
before thread create
before capture
after thread create
after capture: hello foo
capture: hello bar
--- no_error_log
[error]



=== TEST 13: two simple user threads doing single subrequests (entry also does a subrequest and quits between)
--- config
    location /lua {
        content_by_lua '
            function f()
                ngx.say("f: before capture")
                local res = ngx.location.capture("/proxy?foo")
                ngx.say("f: after capture: ", res.body)
            end

            function g()
                ngx.say("g: before capture")
                local res = ngx.location.capture("/proxy?bah")
                ngx.say("g: after capture: ", res.body)
            end

            ngx.say("before thread 1 create")
            ngx.thread.create(f)
            ngx.say("after thread 1 create")

            ngx.say("before thread 2 create")
            ngx.thread.create(g)
            ngx.say("after thread 2 create")

            local res = ngx.location.capture("/proxy?bar")
            ngx.say("capture: ", res.body)
        ';
    }

    location /proxy {
        proxy_pass http://127.0.0.1:$server_port/$args;
    }

    location /foo {
        echo_sleep 0.1;
        echo -n hello foo;
    }

    location /bar {
        echo_sleep 0.2;
        echo -n hello bar;
    }

    location /bah {
        echo_sleep 0.3;
        echo -n hello bah;
    }
--- request
GET /lua
--- stap2 eval: $::StapScript
--- stap eval: $::GCScript
--- stap_out
create user thread 2 in 1
create user thread 3 in 1
delete thread 2
delete thread 1
delete thread 3

--- response_body
before thread 1 create
f: before capture
after thread 1 create
before thread 2 create
g: before capture
after thread 2 create
f: after capture: hello foo
capture: hello bar
g: after capture: hello bah
--- no_error_log
[error]

