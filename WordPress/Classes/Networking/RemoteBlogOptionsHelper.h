#import <Foundation/Foundation.h>

@interface RemoteBlogOptionsHelper : NSObject

+ (NSDictionary *)mapOptionsFromResponse:(NSDictionary *)response;

/* Helper methods for getting the default categoryID or postFormat, which can appear both in remote blog options
   and the WPCOM endpoint for blog/settings.
 */
+ (NSNumber *)defaultCategoryIDFromOptions:(NSDictionary *)options;
+ (NSString *)defaultPostFormatFromOptions:(NSDictionary *)options;

@end
