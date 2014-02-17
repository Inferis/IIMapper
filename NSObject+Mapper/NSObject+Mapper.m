//
//  NSObject+Mapper.m
//
//  Created by Tom Adriaenssen on 27/02/12.
//

#import "NSObject+Mapper.h"
#import "Coby.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "CommonMacros.h"

@interface NSObject (Mapper_Overrides) // no implementation below, can be implemented by NSObjects

- (void)mapper_completeInContext:(NSManagedObjectContext *)context;
- (void)mapper_complete;

- (NSDictionary*)mapper_mappingDictionary;
- (BOOL)mapper_boolFromString:(NSString*)string;
- (char)mapper_charFromString:(NSString*)string;
- (NSDate*)mapper_dateFromString:(NSString*)string;

@end

@implementation NSObject (Mapper)

- (void)applyFromObject:(id)object {
    [[self class] mapper_mapValuesToObject:self fromObject:object];
}

- (void)applyFromDictionary:(NSDictionary *)dictionary {
    [[self class] mapper_mapValuesToObject:self fromObject:dictionary];
}

+ (NSArray*)mappedArrayFromArray:(NSArray*)source {
    if (!source || [source isKindOfClass:[NSNull class]])
        return nil;
    return [source map:^id(id obj) {
        // if classes are the same, just map directly
        if ([obj isKindOfClass:self])
            return obj;

        return [self mappedObjectFromDictionary:obj];
    }];
}

+ (id)mappedObjectFromDictionary:(NSDictionary *)dictionary {
    if (!dictionary || [dictionary isKindOfClass:[NSNull class]])
        return nil;
    id result = [[self alloc] init];
    [self mapper_mapValuesToObject:result fromObject:dictionary];
    return result;
}

+ (id)mappedObjectFromObject:(id)object;
{
    if (!object || [object isKindOfClass:[NSNull class]])
        return nil;

    id result = [[self alloc] init];
    [self mapper_mapValuesToObject:result fromObject:object];
    return result;
}

+ (id)createObjectFromObject:(id)object {
    return [self mappedObjectFromObject:object];
}

+ (NSDictionary*)dictionaryFromObject:(id)object {
    NSDictionary* mappingDictionary = [self mapper_getMappingDictionary];
    return [NSDictionary dictionaryWithDictionary:[object mapper_getValuesUsingMappingDictionary:mappingDictionary]];
}

+ (NSString*)mappedPropertyForJsonKey:(NSString*)field
{
    NSDictionary* mappingDictionary = [self mapper_getMappingDictionary];
    __block NSString* result = nil;
    [mappingDictionary enumerateKeysAndObjectsUsingBlock:^(NSString* property, NSString* jsonKey, BOOL *stop) {
        if ([jsonKey isEqualToString:field]) {
            result = property;
            *stop = YES;
        }
    }];
    return result;
}


+ (void)mapper_mapValuesToObject:(id)result fromObject:(id)object {
    NSDictionary* mappingDictionary = [self mapper_getMappingDictionary];
    [result mapper_setValuesFromObject:object usingMappingDictionary:mappingDictionary];
}


- (NSMutableDictionary*)mapper_getValuesUsingMappingDictionary:(NSDictionary *)translationDictionary {
    id(^get_value)(id obj, NSString* key) = [self valueGetterForObject:self];

    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    [translationDictionary enumerateKeysAndObjectsUsingBlock:^(NSString* property, NSString* jsonKey, BOOL *stop) {
        id fetchedObj = get_value(self, property);
        if (fetchedObj != nil)
            result[jsonKey] = fetchedObj;
    }];
    
    return result;
}

- (id(^)(id obj, NSString* key))valueGetterForObject:(id)object {
    if ([object isKindOfClass:[NSDictionary class]]) {
        return (id)^(id obj, NSString* key) {
            return [(NSDictionary*)obj fetch:key default:@""];
        };
    }
    else {
        return (id)^(id obj, NSString* key) {
            SEL selector = NSSelectorFromString(key);
            if (![obj respondsToSelector:selector])
                return (id)nil;
            
            char typeEncoding;
            method_getReturnType(class_getInstanceMethod([obj class], NSSelectorFromString(key)), &typeEncoding, sizeof(typeEncoding));
            
            return [obj valueForKey:key];
        };
    }
    
}

- (void)mapper_setValuesFromObject:(id)object usingMappingDictionary:(NSDictionary *)translationDictionary {
    id(^get_value)(id obj, NSString* key) = [self valueGetterForObject:object];
    
    [translationDictionary enumerateKeysAndObjectsUsingBlock:^(NSString* property, NSString* jsonKey, BOOL *stop) {
        id fetchedObj = get_value(object, jsonKey);
        // Don't try to set empty values
        if (IsEmpty(fetchedObj)) return;
        // Don't try to set <null> data
        if ([fetchedObj isEqual:@"<null>"]) return;
        
        [self mapper_transformAndSetValue:fetchedObj forProperty:property class:nil];
    }];
    
    [self mapper_performComplete];
}

- (void)mapper_performComplete {
    SEL completeSelector = @selector(mapper_complete);
    if ([self respondsToSelector:completeSelector]) {
        [self mapper_complete];
    }
}

+ (NSDictionary*)mapper_getMappingDictionary {
    if ([self respondsToSelector:@selector(mapper_mappingDictionary)]) {
        NSDictionary* result = [self performSelector:@selector(mapper_mappingDictionary)];
        if (result) 
            return result;
    }

    return [self mapper_propertywiseMappingDictionary:self];
}

+ (BOOL)mapper_isNSClass:(Class)class {
    return [NSStringFromClass(class) rangeOfString:@"NS"].location == 0;
}

+ (NSDictionary*)mapper_propertywiseMappingDictionary:(Class)class {
    if (!class) return [NSDictionary dictionary];
    
    // we'll do a property wise mapping
    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    
	unsigned int propertyCount;
	objc_property_t *properties = class_copyPropertyList(class, &propertyCount);
	for (int i=0; i<propertyCount; i++) {
		objc_property_t property = properties[i];
		NSString *keyName = [NSString stringWithUTF8String:property_getName(property)];
        [result set:keyName for:keyName];
    }
    free(properties);
    
    if ([class superclass] && ![self mapper_isNSClass:[class superclass]]) {
        [result addEntriesFromDictionary:[self mapper_propertywiseMappingDictionary:[class superclass]]];
    }
    
    return result;
}


- (void)mapper_transformAndSetValue:(id)value forProperty:(NSString*)propertyName class:(Class)class
{
    SEL transformSelector = NSSelectorFromString([NSString stringWithFormat:@"mapper_transform_%@:", propertyName]);
    if ([[self class] respondsToSelector:transformSelector]) {
        id (*objc_msgSendTyped)(id self, SEL _cmd, id value) = (void*)objc_msgSend;
        value = objc_msgSendTyped([self class], transformSelector, value);
    }

    if (!class) class = [self class];
    while (YES) {
        unsigned int propertyCount;
        objc_property_t *properties = class_copyPropertyList(class, &propertyCount);
        
        for (int i=0; i<propertyCount; i++) {
            objc_property_t property = properties[i];
            NSString *keyName = [NSString stringWithUTF8String:property_getName(property)];
            if ([keyName isEqualToString:propertyName]) {
                char *typeEncoding = NULL;
                typeEncoding = property_copyAttributeValue(property, "T");
                
                if (typeEncoding == NULL) {
                    continue;
                }
                switch (typeEncoding[0]) {
                    case '@':
                    {
                        // Object
                        Class class = nil;
                        if (strlen(typeEncoding) >= 3) {
                            char *className = strndup(typeEncoding+2, strlen(typeEncoding)-3);
                            class = NSClassFromString([NSString stringWithUTF8String:className]);
                            free(className);
                        }
                        // Check for type mismatch, attempt to compensate
                        if ([class isSubclassOfClass:[NSString class]] && [value isKindOfClass:[NSNumber class]]) {
                            value = [value stringValue];
                        }
                        else if ([class isSubclassOfClass:[NSNumber class]] && [value isKindOfClass:[NSString class]]) {
                            // If the ivar is an NSNumber we really can't tell if it's intended as an integer, float, etc.
                            NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
                            [numberFormatter setNumberStyle:NSNumberFormatterDecimalStyle];
                            value = [numberFormatter numberFromString:value];
                        }
                        else if ([class isSubclassOfClass:[NSDate class]] && [value isKindOfClass:[NSString class]]) {
                            if ([[self class] respondsToSelector:@selector(mapper_dateFromString:)])
                                value = [[self class] performSelector:@selector(mapper_dateFromString:) withObject:value];
                            else
                                value = [NSDate dateWithISO8601String:value];
                        }
                        else if ([class isSubclassOfClass:[NSArray class]] && [value isKindOfClass:[NSArray class]]) {
                            SEL itemClassSelector = NSSelectorFromString([NSString stringWithFormat:@"mapper_%@_itemClass", propertyName]);
                            if ([[self class] respondsToSelector:itemClassSelector]) {
                                Class (*objc_msgSendTyped)(id self, SEL _cmd) = (void*)objc_msgSend;
                                Class itemClass = objc_msgSendTyped([self class], itemClassSelector);

                                if (!itemClass) {
                                    NSString* error = [NSString stringWithFormat:@"No class returned from [%@ mapper_%@_itemClass]. Can't map array property %@.", [self class], propertyName, propertyName];
                                    NSAssert(NO, error);
                                }
                                value = [itemClass mappedArrayFromArray:value];
                                break;
                            }

                            SEL itemTransformSelector = NSSelectorFromString([NSString stringWithFormat:@"mapper_%@_transformItem:", propertyName]);
                            if ([[self class] respondsToSelector:itemTransformSelector]) {
                                id(*objc_msgSendTyped)(id self, SEL _cmd, id item) = (void*)objc_msgSend;
                                value = [(NSArray*)value map:^id(id item) {
                                    return objc_msgSendTyped([self class], itemTransformSelector, item);
                                }];
                                break;
                            }

                            NSString* error = [NSString stringWithFormat:@"define [%@ mapper_%@_itemClass] or [%@ mapper_%@_itemAdapter] to implement item mapping for array property %@.", [self class], propertyName, propertyName, propertyName, propertyName];
                            DLog(@"error = %@", error);
                            NSAssert(NO, error);
                        }

                        break;
                    }
                        
                    case 'i': // int
                    case 's': // short
                    case 'l': // long
                    case 'q': // long long
                    case 'I': // unsigned int
                    case 'S': // unsigned short
                    case 'L': // unsigned long
                    case 'Q': // unsigned long long
                    case 'f': // float
                    case 'd': // double
                    {
                        if ([value isKindOfClass:[NSString class]]) {
                            NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
                            [numberFormatter setNumberStyle:NSNumberFormatterDecimalStyle];
                            value = [numberFormatter numberFromString:value];
                        }
                    }
                        
                    case 'B': // BOOL
                    {
                        if ([value isKindOfClass:[NSString class]]) {
                            if ([[self class] respondsToSelector:@selector(mapper_boolFromString:)])
                                value = [[self class] performSelector:@selector(mapper_boolFromString:) withObject:value];
                            else {
                                NSString* lvalue = [value lowercaseString];
                                if ([lvalue isEqualToString:@"yes"] || [lvalue isEqualToString:@"true"]) {
                                    value = [NSNumber numberWithBool:YES];
                                }
                                else if ([lvalue isEqualToString:@"no"] || [lvalue isEqualToString:@"false"]) {
                                    value = [NSNumber numberWithBool:NO];
                                }
                                else {
                                    NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
                                    [numberFormatter setNumberStyle:NSNumberFormatterDecimalStyle];
                                    value = [NSNumber numberWithBool:[[numberFormatter numberFromString:value] intValue] != 0];
                                }
                            }
                        }
                        break;
                    }
                        
                    case 'c': // char
                    case 'C': // unsigned char
                    {
                        if ([value isKindOfClass:[NSString class]]) {
                            if ([[self class] respondsToSelector:@selector(mapper_charFromString:)])
                                value = [[self class] performSelector:@selector(mapper_charFromString:) withObject:value];
                            else {
                                NSString* lvalue = [value lowercaseString];
                                if ([lvalue isEqualToString:@"yes"] || [lvalue isEqualToString:@"true"]) {
                                    value = [NSNumber numberWithChar:1];
                                }
                                else if ([lvalue isEqualToString:@"no"] || [lvalue isEqualToString:@"false"]) {
                                    value = [NSNumber numberWithChar:0];
                                }
                                else {
                                    char firstCharacter = [value characterAtIndex:0];
                                    value = [NSNumber numberWithChar:firstCharacter];
                                }
                            }
                        }
                        break;
                    }
                        
                    default:
                    {
                        break;
                    }
                }
                
                // check if we can actually set the property
                NSString* setter = [NSString stringWithFormat:@"set%@%@:", [[keyName substringToIndex:1] uppercaseString], [keyName substringFromIndex:1]];
                SEL selector = NSSelectorFromString(setter);
                if ([self respondsToSelector:NSSelectorFromString(setter)]) {
                    switch (typeEncoding[0]) {
                        case 'i': { // int
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, int value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value intValue]);
                            break;
                        }

                        case 's': { // short
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, short value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value shortValue]);
                            break;
                        }

                        case 'l': { // long
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, long value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value longValue]);
                            break;
                        }

                        case 'q': { // long long
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, long long value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value longLongValue]);
                            break;
                        }

                        case 'I': { // unsigned int
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, unsigned int value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value unsignedIntValue]);
                            break;
                        }

                        case 'S': { // unsigned short
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, unsigned short value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value unsignedShortValue]);
                            break;
                        }

                        case 'L': { // unsigned long
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, unsigned long value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value unsignedLongValue]);
                            break;
                        }

                        case 'Q': { // unsigned long long
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, unsigned long long value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value unsignedLongLongValue]);
                            break;
                        }

                        case 'f': { // float
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, float value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value floatValue]);
                            break;
                        }

                        case 'd': { // double
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, double value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value doubleValue]);
                            break;
                        }
                            
                        case 'B': { // BOOL
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, BOOL value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value boolValue]);
                            break;
                        }
                            
                        case 'c': { // char
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, char value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value charValue]);
                            break;
                        }

                        case 'C': { // unsigned char
                            BOOL (*objc_msgSendTyped)(id self, SEL _cmd, unsigned char value) = (void*)objc_msgSend;
                            objc_msgSendTyped(self, selector, [value unsignedCharValue]);
                            break;
                        }
                            
                        default: { // objects and fallback
                            // special case
                            if ([value isKindOfClass:[NSNumber class]] && strcmp(typeEncoding, "@\"NSDecimalNumber\"") == 0) {
                                value = [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%@", value]];
                            }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            [self performSelector:selector withObject:value];
#pragma clang diagnostic pop
                            //objc_msgSend(self, selector, value);
                            break;
                        }
                    }

                }
                free(typeEncoding);
                free(properties);
                return;
            }
        }
        free(properties);
        
        if ([class superclass] && ![[self class] mapper_isNSClass:[class superclass]]) {
            class = [class superclass];
        }
        else
            return;
    }
}

@end

