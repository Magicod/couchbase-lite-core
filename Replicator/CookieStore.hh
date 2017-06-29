//
//  CookieStore.hh
//  LiteCore
//
//  Created by Jens Alfke on 6/8/17.
//  Copyright © 2017 Couchbase. All rights reserved.
//

#pragma once
#include "RefCounted.hh"
#include "Address.hh"
#include "FleeceCpp.hh"
#include <iostream>
#include <memory>
#include <mutex>
#include <time.h>
#include <vector>

namespace litecore { namespace repl {

    /** Represents an HTTP cookie. */
    struct Cookie {
        // The constructors won't throw exceptions on invalid input, but the resulting Cookie
        // will return false from valid().

        Cookie() =default;
        Cookie(const std::string &header, const std::string &fromHost);
        Cookie(fleeceapi::Dict);

        explicit operator bool() const  {return valid();}
        bool valid() const              {return !name.empty();}
        bool persistent() const         {return expires > 0;}
        bool expired() const            {return expires > 0 && expires < time(NULL);}

        bool matches(const Cookie&) const;
        bool matches(const websocket::Address&) const;
        bool sameValueAs(const Cookie&) const;

        std::string name;
        std::string value;
        std::string domain;
        std::string path;
        time_t created;
        time_t expires      {0};
        bool secure         {false};
    };

    std::ostream& operator<< (std::ostream&, const Cookie&);
    fleeceapi::Encoder& operator<< (fleeceapi::Encoder&, const Cookie&);


    /** Stores cookies, with support for persistent storage.
        Cookies are added from Set-Cookie headers, and the instance can generate Cookie: headers to
        send in requests.
        Instances are thread-safe. */
    class CookieStore : public RefCounted {
    public:
        CookieStore() =default;
        CookieStore(fleece::slice data);

        fleece::alloc_slice encode();

        std::vector<const Cookie*> cookies() const;
        std::string cookiesForRequest(const websocket::Address&) const;

        // Adds a cookie from a Set-Cookie: header value. Returns false if cookie is invalid.
        bool setCookie(const std::string &headerValue, const std::string &fromHost);
        
        void clearCookies();

        void merge(fleece::slice data);

        bool changed();
        void clearChanged();

    private:
        using CookiePtr = std::unique_ptr<const Cookie>;

        void _addCookie(CookiePtr newCookie);

        CookieStore(const CookieStore&) =delete;

        std::vector<CookiePtr> _cookies;
        bool _changed {false};
        std::mutex _mutex;
    };

} }
