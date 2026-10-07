#import <Foundation/Foundation.h>
#include "BodyDecoder.h"

char *ma_decode_body(const void *bytes, size_t count) {
    @autoreleasepool {
        @try {
            NSData *data = [NSData dataWithBytes:bytes length:count];
            id object = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if (count >= 8 && !memcmp(bytes, "bplist00", 8)) {
                object = [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:data error:nil];
            } else {
                object = [NSUnarchiver unarchiveObjectWithData:data];
            }
#pragma clang diagnostic pop
            NSString *text = nil;
            if ([object isKindOfClass:[NSAttributedString class]]) text = [object string];
            else if ([object isKindOfClass:[NSString class]]) text = object;
            return text ? strdup(text.UTF8String) : NULL;
        } @catch (NSException *exception) { return NULL; }
    }
}
