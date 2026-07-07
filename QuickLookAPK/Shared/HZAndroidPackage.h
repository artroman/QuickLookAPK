//
//  HZAndroidPackage.h
//  QuickLookAPK
//
//  Created by Hezi Cohen on 1/21/14.
//  Copyright (c) 2014 Hezi Cohen. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface HZAndroidPackage : NSObject

@property(nonatomic) NSString *path;
@property(nonatomic) NSString *name;
@property(nonatomic) NSInteger versionCode;
@property(nonatomic) NSString *versionName;
@property(nonatomic) NSString *label;
@property(nonatomic) NSInteger minSdkVersion;
@property(nonatomic) NSInteger targetSdkVersion;
@property(nonatomic) NSInteger maxSdkVersion;
@property(nonatomic) NSString *iconPath;
@property(nonatomic) NSString *iconType;
@property(nonatomic) NSString *iconResourceId;
@property(nonatomic) NSData *iconData;
@property(nonatomic) NSArray *permissions;
@property(nonatomic) NSString *nativeLibraries;

+ (instancetype)packageWithPath:(NSString *)path;

@end

NSData *dataFromZipPath(NSString *zipFile, NSString *pathInZip);
NSString *androidPackageHTMLPreview(HZAndroidPackage *package);
