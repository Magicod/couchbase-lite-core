//
//  Error.cc
//  CBForest
//
//  Created by Jens Alfke on 3/4/16.
//  Copyright © 2016 Couchbase. All rights reserved.
//

#include "Error.hh"
#include "LogInternal.hh"
#include "forestdb.h"
#include <sqlite3.h>
#include <string>


namespace cbforest {

    static const char* kDomainNames[] = {"CBForest", "POSIX", "ForestDB", "SQLite", "HTTP"};

    static const char* cbforest_errstr(error::CBForestError code) {
        static const char* kCBForestMessages[] = {
            "no error",
            "assertion failed",
            "unimplemented function called",
            "database doesn't support sequences",
            "unsupported encryption algorithm",
            "call must be made in a transaction",
            "bad revision ID",
            "bad version vector",
            "corrupt revision data",
            "corrupt index",
            "text tokenizer error",
        };
        if (code < sizeof(kCBForestMessages)/sizeof(char*))
            return kCBForestMessages[code];
        else
            return "(unknown CBForestError)";
    }

    const char* error::what() const noexcept {
        switch (domain) {
            case CBForest:
                return cbforest_errstr((CBForestError)code);
            case POSIX:
                return strerror(code);
            case ForestDB:
                return fdb_error_msg((fdb_status)code);
            case SQLite:
                return sqlite3_errstr(code);
            default:
                return "cbforest::error?";
        }
    }

    
    void error::_throw(Domain domain, int code ) {
        CBFDebugAssert(code != 0);
        error err{domain, code};
        switch (domain) {
            case CBForest:
            case POSIX:
            case ForestDB:
            case SQLite:
                WarnError("CBForest throwing %s error %d: %s",
                          kDomainNames[domain], code, err.what());
                break;
            default:
                WarnError("CBForest throwing %s error %d", kDomainNames[domain], code);
                break;
        }
        throw err;
    }

    
    void error::_throw(error::CBForestError err) {
        _throw(CBForest, err);
    }

    void error::_throwHTTPStatus(int status) {
        _throw(HTTP, status);
    }


    void error::assertionFailed(const char *fn, const char *file, unsigned line, const char *expr) {
        if (LogLevel > kError || LogCallback == NULL)
            fprintf(stderr, "Assertion failed: %s (%s:%u, in %s)", expr, file, line, fn);
        WarnError("Assertion failed: %s (%s:%u, in %s)", expr, file, line, fn);
        throw error(error::AssertionFailed);
    }


#pragma mark - LOGGING:

    
    static void defaultLogCallback(logLevel level, const char *message) {
        static const char* kLevelNames[4] = {"debug", "info", "WARNING", "ERROR"};
        fprintf(stderr, "CBForest %s: %s\n", kLevelNames[level], message);
    }

    logLevel LogLevel = kWarning;
    void (*LogCallback)(logLevel, const char *message) = &defaultLogCallback;

    void _Log(logLevel level, const char *message, ...) {
        if (LogLevel <= level && LogCallback != NULL) {
            va_list args;
            va_start(args, message);
            char *formatted = NULL;
            vasprintf(&formatted, message, args);
            va_end(args);
            LogCallback(level, formatted);
        }
    }
    
}