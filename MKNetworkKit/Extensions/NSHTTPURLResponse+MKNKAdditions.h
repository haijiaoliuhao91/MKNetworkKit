//
//  NSHTTPURLResponse+MKNKAdditions.h
//  Tokyo
//
//  Created by Mugunth on 30/7/14.
//  Copyright (c) 2014 LifeOpp Pte Ltd. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NSHTTPURLResponse (MKNKAdditions)
@property (readonly) NSDate* cacheExpiryDate;
@end
