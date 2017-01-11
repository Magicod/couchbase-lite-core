//
//  LCQuery+Predicates.m
//  LiteCore
//
//  Created by Jens Alfke on 1/10/17.
//  Copyright © 2017 Couchbase. All rights reserved.
//

#import "LCQuery+Predicates.h"
#import "LC_Internal.h"
#import "Fleece.h"


#if DEBUG
static void DumpPredicate(NSPredicate *pred, int indent);
#endif


@implementation LCQuery (Predicates)


// https://github.com/couchbase/couchbase-lite-core/wiki/JSON-Query-Schema
// https://developer.apple.com/library/content/documentation/Cocoa/Conceptual/Predicates/Articles/pSyntax.html
// https://developer.apple.com/library/content/documentation/Cocoa/Conceptual/KeyValueCoding/CollectionOperators.html

// Maps NSPredicateOperatorType to query operator.
// See <Foundation/NSComparisonPredicate.h> lines 26-39
static NSString* const kPredicateOpNames[] = {
    @"<", @"<=", @">", @">=", @"=", @"!=",
    @"REGEXP_LIKE()",   // NSPredicate's MATCH is a regex
    @"GLOB",            // NSPredicate's "LIKE" is comparable to SQL/N1QL "GLOB", not "LIKE"
    nil, nil,           // TODO: Implement begins with, ends with
    @"IN",
    nil,                // 'custom selector'
};
static NSString* const kPredicateOpNames99[] = {
    @"CONTAINS()",
    @"BETWEEN"
};


// Maps NSExpression function selector to query operator.
// See <Foundation/NSExpression.h> lines 55-94
// https://developer.couchbase.com/documentation/server/4.5/n1ql/n1ql-language-reference/functions.html
static NSDictionary* const  kFunctionNames = @{ @"sum":            @"+",
                                                @"add:to:":        @"+",
                                                @"from:subtract:": @"-",
                                                @"multiply:by:":   @"*",
                                                @"divide:by:":     @"/",
                                                @"modulus:by:":    @"%",
                                                @"count:":         @"ARRAY_COUNT()",
                                                @"sqrt:":          @"SQRT()",
                                                @"log:":           @"LOG()",
                                                @"ln:":            @"LN()",
                                                @"exp:":           @"EXP()",
                                                @"raise:toPower:": @"POWER()",
                                                @"floor:":         @"FLOOR()",
                                                @"ceiling:":       @"CEIL()",
                                                @"abs:":           @"ABS()",
                                                @"uppercase:":     @"UPPER()",
                                                @"lowercase:":     @"LOWER()",
                                                @"length:":        @"LENGTH()",
                                                // special cases (undocumented by Apple):
                                                @"valueForKeyPath:": @".",
                                                @"objectFrom:withIndex:": @"[]",
                                              };


// Translates an NSPredicate into the JSON-dictionary equivalent of a WHERE clause
+ (id) encodePredicate: (NSPredicate*)pred
                 error: (NSError**)outError
{
    return EncodePredicate(pred, outError);
}


static id EncodePredicate(NSPredicate* pred, NSError** outError) {
    if ([pred isKindOfClass: [NSComparisonPredicate class]]) {
        // Comparison of expressions, e.g. "a < b":
        NSComparisonPredicate* cp = (NSComparisonPredicate*)pred;
        NSPredicateOperatorType opType = cp.predicateOperatorType;
        NSString *op = predicateOperatorName(opType);
        if (!op)
            return mkError(outError, @"Unsupported comparison operator %d", opType), nil;

        if (opType == NSBetweenPredicateOperatorType) {
            // BETWEEN needs some translation -- the range is in an array encoded in the RHS
            NSExpression* lhs = EncodeExpression(cp.leftExpression, outError);
            if (!lhs) return nil;
            NSArray* range = cp.rightExpression.collection;
            id min = EncodeExpression(range[0], outError);
            if (!min) return nil;
            id max = EncodeExpression(range[1], outError);
            if (!max) return nil;
            return @[op, lhs, min, max];
        }

        // TODO: Support NSCaseInsensitivePredicateOption etc.
        NSExpression* rhs = EncodeExpression(cp.rightExpression, outError);
        if (!rhs) return nil;

        if (opType == NSInPredicateOperatorType) {
            // IN needs translation if RHS is not a literal or property
            NSExpressionType rtype = cp.rightExpression.expressionType;
            if (rtype != NSVariableExpressionType && rtype != NSAggregateExpressionType) {
                NSExpression* lhs = EncodeExpression(cp.leftExpression, outError);
                if (!lhs) return nil;
                return @[@"ANY", @"X", rhs, @[@"=", @[@"?X"], lhs]];
            }
        }

        static NSString* const kModifiers[3] = {nil, @"EVERY", @"ANY"};
        NSString* mod = kModifiers[cp.comparisonPredicateModifier];
        if (mod == nil) {
            NSExpression* lhs = EncodeExpression(cp.leftExpression, outError);
            if (!lhs) return nil;
            return @[op, lhs, rhs];
        } else {
            // ANY or EVERY modifiers: (I'm assuming they will always have a key-path as the LHS.)
            NSString* keyPath = cp.leftExpression.keyPath;
            NSString* lastProp = nil;
            NSRange dot = [keyPath rangeOfString: @"." options: NSBackwardsSearch];
            if (dot.length > 0) {
                lastProp = [keyPath substringFromIndex: NSMaxRange(dot)];
                keyPath = [keyPath substringToIndex: dot.location];
            }
            return @[mod, @"X", encodeKeyPath(keyPath),
                     @[op, (lastProp ? @[@"?X", lastProp] : @[@"?X"]),
                       rhs]];
        }

    } else if ([pred isKindOfClass: [NSCompoundPredicate class]]) {
        // Logical compound of sub-predicates, e.g. "a AND b AND c":
        static NSString* const kCompoundOpNames[] = {@"NOT", @"AND", @"OR"};
        NSCompoundPredicate* cp = (NSCompoundPredicate*)pred;
        NSMutableArray *result = [NSMutableArray new];
        [result addObject: kCompoundOpNames[cp.compoundPredicateType]];
        for (NSPredicate* subPred in cp.subpredicates) {
            id obj = EncodePredicate(subPred, outError);
            if (!obj)
                return nil;
            [result addObject: obj];
        }
        return result;

    } else {
        return mkError(outError, @"Unsupported NSPredicate type %@", [pred class]), nil;
    }

}


static id EncodeExpression(NSExpression* expr, NSError **outError) {
    switch (expr.expressionType) {
        case NSConstantValueExpressionType:
            return expr.constantValue;
        case NSVariableExpressionType:
            return @[ [@"$" stringByAppendingString: expr.variable] ];
        case NSKeyPathExpressionType: {
            for (NSString* prop in [expr.keyPath componentsSeparatedByString: @"."])
                if ([prop hasPrefix: @"@"])
                    return mkError(outError, @"Key-path collection operators not supported yet"), nil;
            return encodeKeyPath(expr.keyPath);
        }
        case NSFunctionExpressionType: {
            NSString* fn = kFunctionNames[expr.function];
            if (fn == nil) {
                return mkError(outError, @"Unsupported function '%@'", expr.function), nil;
            } else if ([fn isEqualToString: @"."]) {
                // This is a weird case where using "first" or "last" in a key-path compiles to a
                // predicate containing an undocumented expression type...
                NSString* keyPath = [NSString stringWithFormat: @"%@.%@",
                                     expr.operand.keyPath,
                                     expr.arguments[0].description.lowercaseString];
                return encodeKeyPath(keyPath);
            } else if ([fn isEqualToString: @"[]"]) {
                // Array indexing: Weirdly, the operand is some internal object and the array
                // and index are the two elements of the arguments
                NSArray *operand = EncodeExpression(expr.arguments[0], outError);
                if (!operand) return nil;
                NSString* keyPath = operand[0];
                if (![keyPath hasPrefix: @"."])
                    return mkError(outError, @"Can't index this as an array"), nil;
                id indexObj = EncodeExpression(expr.arguments[1], outError);
                if (!indexObj) return nil;
                NSInteger index;
                if ([indexObj isKindOfClass: [NSNumber class]])
                    index = [indexObj integerValue];
                else if ([indexObj isEqual: @[@".first"]])
                    index = 0;
                else if ([indexObj isEqual: @[@".last"]])
                    index = -1;
                else if ([indexObj isEqual: @[@".size"]])
                    return @[@"ARRAY_COUNT()", operand];
                else
                    return mkError(outError, @"Array index must be constant"), nil;
                return @[ [NSString stringWithFormat: @"%@[%ld]", keyPath, index] ];
            } else {
                // Regular function call:
                id p = EncodeExpression(expr.operand, outError);
                if (!p) return nil;
                NSMutableArray* result = [NSMutableArray arrayWithObject: fn];
                [result addObject: p];
                for(NSExpression* param in expr.arguments) {
                    p = EncodeExpression(param, outError);
                    if (!p) return nil;
                    [result addObject: p];
                }
                return result;
            }
        }
        case NSConditionalExpressionType: {
            id condition = EncodePredicate(expr.predicate, outError);
            if (!condition) return nil;
            id ifTrue = EncodeExpression(expr.trueExpression, outError);
            if (!ifTrue) return nil;
            id ifFalse = EncodeExpression(expr.falseExpression, outError);
            if (!ifFalse) return nil;
            return @[@"CASE", condition, @[@"WHEN", @YES, ifTrue], @[@"ELSE", ifFalse]];
        }
        default:
            if ((int)expr.expressionType == 11) {
                // Undocumented type; this seems to correspond to using one
                // of the reserved words (FIRST, LAST, SIZE...) as a property name.
                return encodeKeyPath(expr.description.lowercaseString);
            }
            return mkError(outError, @"Unsupported NSExpression type %d", expr.expressionType), nil;
    }
}


static NSArray* encodeKeyPath(NSString *keyPath) {
    return @[ [@"." stringByAppendingString: keyPath] ];
}


static NSString* predicateOperatorName(NSPredicateOperatorType op) {
    int iop = (int)op;
    NSString* const * table = kPredicateOpNames;
    unsigned n = sizeof(kPredicateOpNames) / sizeof(NSString*);
    if (iop >= 99) {
        iop -= 99;
        table = kPredicateOpNames99;
        n = sizeof(kPredicateOpNames99) / sizeof(NSString*);
    }
    return (iop < n) ? table[iop] : nil;
}


#if DEBUG
+ (void) dumpPredicate: (NSPredicate*)pred {
    DumpPredicate(pred, 0);
}


void DumpPredicate(NSPredicate *pred, int indent) {
    for (int i=0; i < indent; i++) fprintf(stderr, "    ");
    fprintf(stderr, "%s ", NSStringFromClass(pred.class).UTF8String);
    if ([pred isKindOfClass: [NSComparisonPredicate class]]) {
        // Comparison of expressions, e.g. "a < b":
        NSComparisonPredicate* cp = (NSComparisonPredicate*)pred;
        fprintf(stderr, "%d; mod %d, opt %d\n",
                (int)cp.predicateOperatorType, (int)cp.comparisonPredicateModifier, (int)cp.options);
        DumpExpression(cp.leftExpression, indent+1);
        DumpExpression(cp.rightExpression, indent+1);
    } else if ([pred isKindOfClass: [NSCompoundPredicate class]]) {
        // Logical compound of sub-predicates, e.g. "a AND b AND c":
        static const char* const kCompoundOpNames[] = {"NOT", "AND", "OR"};
        NSCompoundPredicate* cp = (NSCompoundPredicate*)pred;
        fprintf(stderr, "%s\n", kCompoundOpNames[cp.compoundPredicateType]);
        for (NSPredicate *p in cp.subpredicates)
            DumpPredicate(p, indent+1);
    } else {
        fprintf(stderr, "???\n");
    }

}


static void DumpExpression(NSExpression* expr, int indent) {
    for (int i=0; i < indent; i++) fprintf(stderr, "    ");
    fprintf(stderr, "%s ", NSStringFromClass(expr.class).UTF8String);
    switch (expr.expressionType) {
        case NSConstantValueExpressionType:
            fprintf(stderr, "%s\n", [expr.constantValue description].UTF8String);
            return;
        case NSVariableExpressionType:
            fprintf(stderr, "%s\n", expr.variable.UTF8String);
            return;
        case NSKeyPathExpressionType:
            fprintf(stderr, "%s\n", expr.keyPath.UTF8String);
            return;
        case NSFunctionExpressionType: {
            fprintf(stderr, "%s\n", expr.function.UTF8String);
            DumpExpression(expr.operand, indent+1);
            for (NSExpression *arg in expr.arguments)
                DumpExpression(arg, indent+1);
            return;
        }
        case NSConditionalExpressionType:
            DumpPredicate(expr.predicate, indent+1);
            DumpExpression(expr.trueExpression, indent+1);
            DumpExpression(expr.falseExpression, indent+1);
            return;
        default:
            fprintf(stderr, "???\n");
            return;
    }
}


+ (NSString*) json5ToJSON: (const char*)json5 {
    FLSliceResult j = FLJSON5_ToJSON(FLSlice{json5, strlen(json5)}, NULL);
    if (!j.buf)
        return nil;
    NSString* json = [[NSString alloc] initWithBytes: j.buf length: j.size encoding: NSUTF8StringEncoding];
    FLSliceResult_Free(j);
    return json;
}
#endif

@end