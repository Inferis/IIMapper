//
//  NSObject+Mapper.h
//
//  Created by Tom Adriaenssen on 27/02/12.
//

#import <Foundation/Foundation.h>

@interface NSObject (Mapper)

- (void)applyFromObject:(id)object;
- (void)applyFromDictionary:(NSDictionary *)dictionary;

+ (NSArray*)mappedArrayFromArray:(NSArray*)source;
+ (id)mappedObjectFromDictionary:(NSDictionary *)dictionary; 
+ (id)mappedObjectFromObject:(id)object;
+ (id)createObjectFromObject:(id)object;

+ (NSDictionary*)dictionaryFromObject:(id)object;

+ (NSString*)mappedPropertyForJsonKey:(NSString*)field;

@end

