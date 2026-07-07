#import "ThumbnailProvider.h"
#import <Cocoa/Cocoa.h>
#import "HZAndroidPackage.h"

@implementation ThumbnailProvider

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request completionHandler:(void (^)(QLThumbnailReply * _Nullable, NSError * _Nullable))handler
{
    HZAndroidPackage *apk = [HZAndroidPackage packageWithPath:request.fileURL.path];
    NSImage *icon = apk.iconData.length ? [[NSImage alloc] initWithData:apk.iconData] : nil;

    if (!icon)
    {
        handler(nil, [NSError errorWithDomain:QLThumbnailErrorDomain code:QLThumbnailErrorGenerationFailed userInfo:nil]);
        return;
    }

    CGSize size = request.maximumSize;
    QLThumbnailReply *reply = [QLThumbnailReply replyWithContextSize:size currentContextDrawingBlock:^BOOL{
        [icon drawInRect:NSMakeRect(0, 0, size.width, size.height)
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0];
        return YES;
    }];

    handler(reply, nil);
}

@end
