#import "RemoteBlogOptionsHelper.h"

static NSString * const RemoteBlogOptionsDefaultCategoryKey = @"default_category";
static NSString * const RemoteBlogOptionsDefaultPostFormatKey = @"default_post_format";

@implementation RemoteBlogOptionsHelper

// Formats blog options retrieved from REST queries
+ (NSDictionary *)mapOptionsFromResponse:(NSDictionary *)response
{
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    options[@"home_url"] = response[@"URL"];
    // We'd be better off saving this as a BOOL property on Blog, but let's do what XML-RPC does for now
    options[@"blog_public"] = [[response numberForKey:@"is_private"] boolValue] ? @"-1" : @"0";
    if ([[response numberForKey:@"jetpack"] boolValue]) {
        options[@"jetpack_client_id"] = [response numberForKey:@"ID"];
    }
    if ( response[@"options"] ) {
        options[@"post_thumbnail"] = [response valueForKeyPath:@"options.featured_images_enabled"];
        NSArray *optionsDirectMapKeys = @[
                                          @"active_modules",
                                          @"admin_url",
                                          @"login_url",
                                          @"image_default_link_type",
                                          @"software_version",
                                          @"videopress_enabled",
                                          @"timezone",
                                          @"gmt_offset",
                                          @"allowed_file_types",
                                          RemoteBlogOptionsDefaultCategoryKey,
                                          RemoteBlogOptionsDefaultPostFormatKey
                                          ];

        for (NSString *key in optionsDirectMapKeys) {
            NSString *sourceKeyPath = [NSString stringWithFormat:@"options.%@", key];
            if ([response valueForKeyPath:sourceKeyPath] != nil) {
                options[key] = [response valueForKeyPath:sourceKeyPath];
            }
        }
    }
    NSMutableDictionary *valueOptions = [NSMutableDictionary dictionaryWithCapacity:options.count];
    [options enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        valueOptions[key] = @{@"value": obj};
    }];

    return [NSDictionary dictionaryWithDictionary:valueOptions ];
}

+ (NSNumber *)defaultCategoryIDFromOptions:(NSDictionary *)options
{
    return [[options dictionaryForKey:RemoteBlogOptionsDefaultCategoryKey] numberForKey:@"value"];
}

+ (NSString *)defaultPostFormatFromOptions:(NSDictionary *)options
{
    return [[options dictionaryForKey:RemoteBlogOptionsDefaultPostFormatKey] stringForKey:@"value"];
}

@end
