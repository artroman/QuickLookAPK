#import "PreviewProvider.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "HZAndroidPackage.h"

@implementation PreviewProvider

- (void)providePreviewForFileRequest:(QLFilePreviewRequest *)request completionHandler:(void (^)(QLPreviewReply * _Nullable, NSError * _Nullable))handler
{
    HZAndroidPackage *apk = [HZAndroidPackage packageWithPath:request.fileURL.path];
    NSData *htmlData = [androidPackageHTMLPreview(apk) dataUsingEncoding:NSUTF8StringEncoding];

    QLPreviewReply *reply = [[QLPreviewReply alloc] initWithDataOfContentType:UTTypeHTML
                                                                   contentSize:CGSizeMake(800, 600)
                                                             dataCreationBlock:^NSData * _Nullable(QLPreviewReply * _Nonnull replyToUpdate, NSError * __autoreleasing _Nullable * _Nullable error) {
        return htmlData;
    }];

    handler(reply, nil);
}

@end
