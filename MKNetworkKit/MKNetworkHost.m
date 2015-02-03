//
//  MKNetworkHost.m
//  MKNetworkKit
//
//  Created by Mugunth Kumar (@mugunthkumar) on 23/06/14.
//  Copyright (C) 2011-2020 by Steinlogic Consulting and Training Pte Ltd

//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "MKNetworkHost.h"

#import "MKCache.h"

#import "NSDate+RFC1123.h"

#import "NSMutableDictionary+MKNKAdditions.h"

#import "NSHTTPURLResponse+MKNKAdditions.h"

NSUInteger const kMKNKDefaultCacheDuration = 600; // 10 minutes
NSUInteger const kMKNKDefaultImageCacheDuration = 3600*24*7; // 7 days
NSString *const kMKCacheDefaultDirectoryName = @"com.mknetworkkit.mkcache";

@interface MKNetworkRequest (/*Private Methods*/)
@property (readwrite) NSHTTPURLResponse *response;
@property (readwrite) NSData *responseData;
@property (readwrite) NSError *error;
@property (readwrite) MKNKRequestState state;
@property (readwrite) NSURLSessionTask *task;
-(void) setProgressValue:(CGFloat) updatedValue;
@end

@interface MKNetworkHost (/*Private Methods*/) <NSURLSessionDelegate>
@property NSURLSessionConfiguration *defaultConfiguration;
@property NSURLSessionConfiguration *secureConfiguration;
@property NSURLSessionConfiguration *backgroundConfiguration;

@property NSURLSession *defaultSession;
@property NSURLSession *secureSession;
@property NSURLSession *backgroundSession;

@property MKCache *dataCache;
@property MKCache *responseCache;

@property dispatch_queue_t runningTasksSynchronizingQueue;
@property NSMutableArray *activeTasks;
@end

@implementation MKNetworkHost

-(instancetype) init {
  
  if((self = [super init])) {
    
    self.defaultConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
    self.secureConfiguration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    
#if (defined(__IPHONE_OS_VERSION_MIN_REQUIRED) && __IPHONE_OS_VERSION_MIN_REQUIRED >= 80000) || (defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && __MAC_OS_X_VERSION_MIN_REQUIRED >= 1100)
    self.backgroundConfiguration =
    [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:
     [[NSBundle mainBundle] bundleIdentifier]];
#else
    self.backgroundConfiguration = [NSURLSessionConfiguration backgroundSessionConfiguration:
                                    [[NSBundle mainBundle] bundleIdentifier]];
#endif
    
    self.defaultSession = [NSURLSession sessionWithConfiguration:self.defaultConfiguration
                                                        delegate:self
                                                   delegateQueue:[[NSOperationQueue alloc] init]];
    
    self.secureSession = [NSURLSession sessionWithConfiguration:self.secureConfiguration
                                                       delegate:self
                                                  delegateQueue:[[NSOperationQueue alloc] init]];
    
    self.backgroundSession = [NSURLSession sessionWithConfiguration:self.backgroundConfiguration
                                                           delegate:self
                                                      delegateQueue:[[NSOperationQueue alloc] init]];
    
    self.runningTasksSynchronizingQueue = dispatch_queue_create("com.mknetworkkit.cachequeue", DISPATCH_QUEUE_SERIAL);
    dispatch_async(self.runningTasksSynchronizingQueue, ^{
      self.activeTasks = [NSMutableArray array];
    });
  }
  
  return self;
}

- (instancetype) initWithHostName:(NSString*) hostName {
  
  MKNetworkHost *engine = [[MKNetworkHost alloc] init];
  engine.hostName = hostName;
  return engine;
}

-(void) enableCache {
  
  [self enableCacheWithDirectory:kMKCacheDefaultDirectoryName inMemoryCost:0];
}

-(void) enableCacheWithDirectory:(NSString*) cacheDirectoryPath inMemoryCost:(NSUInteger) inMemoryCost {
  
  self.dataCache = [[MKCache alloc] initWithCacheDirectory:[NSString stringWithFormat:@"%@/data", cacheDirectoryPath]
                                              inMemoryCost:inMemoryCost];
  
  self.responseCache = [[MKCache alloc] initWithCacheDirectory:[NSString stringWithFormat:@"%@/responses", cacheDirectoryPath]
                                                  inMemoryCost:inMemoryCost];
}

-(void) startUploadRequest:(MKNetworkRequest*) request {
  
  if(request == nil) {
    
    NSLog(@"Request is nil, check your URL and other parameters you use to build your request");
    return;
  }

  request.task = [self.defaultSession uploadTaskWithRequest:request.request
                                                   fromData:request.multipartFormData];
  dispatch_sync(self.runningTasksSynchronizingQueue, ^{
    [self.activeTasks addObject:request];
  });
  request.state = MKNKRequestStateStarted;
}

-(void) startDownloadRequest:(MKNetworkRequest*) request {
  
  if(request == nil) {
    
    NSLog(@"Request is nil, check your URL and other parameters you use to build your request");
    return;
  }

  request.task = [self.defaultSession downloadTaskWithRequest:request.request];
  dispatch_sync(self.runningTasksSynchronizingQueue, ^{
    [self.activeTasks addObject:request];
  });
  request.state = MKNKRequestStateStarted;
}

-(void) startRequest:(MKNetworkRequest*) request {
  
  [self startRequest:request forceReload:YES ignoreCache:YES];
}

-(void) startRequest:(MKNetworkRequest*) request forceReload:(BOOL) forceReload ignoreCache:(BOOL) ignoreCache {
  
  if(request == nil) {
    
    NSLog(@"Request is nil, check your URL and other parameters you use to build your request");
    return;
  }
  if(request.cacheable && !ignoreCache) {
    
    NSHTTPURLResponse *cachedResponse = self.responseCache[@(request.hash)];
    NSDate *cacheExpiryDate = cachedResponse.cacheExpiryDate;
    NSTimeInterval expiryTimeFromNow = [cacheExpiryDate timeIntervalSinceNow];
    
    if(cachedResponse.isContentTypeImage && !cacheExpiryDate) {
      
      expiryTimeFromNow =
      cachedResponse.hasRequiredRevalidationHeaders ? kMKNKDefaultCacheDuration : kMKNKDefaultImageCacheDuration;
    }
    
    if(cachedResponse.hasDoNotCacheDirective || !cachedResponse.hasHTTPCacheHeaders) {
      
      expiryTimeFromNow = kMKNKDefaultCacheDuration;
    }
    
    NSData *cachedData = self.dataCache[@(request.hash)];
    
    if(cachedData) {
      request.responseData = cachedData;
      request.response = cachedResponse;
      
      if(expiryTimeFromNow > 0 && !forceReload) {
        
        request.state = MKNKRequestStateResponseAvailableFromCache;
        return; // don't make another request
      } else {
        
        request.state = expiryTimeFromNow > 0 ? MKNKRequestStateResponseAvailableFromCache :
        MKNKRequestStateStaleResponseAvailableFromCache;
      }
    }
  }
    
  NSURLSession *sessionToUse = self.defaultSession;
  
  if(request.isSSL || request.requiresAuthentication) {
    
    sessionToUse = self.secureSession;
  }
  
  NSURLSessionDataTask *task = [sessionToUse
                                dataTaskWithRequest:request.request
                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                  
                                  if(!response) {
                                    
                                    request.response = (NSHTTPURLResponse*) response;
                                    request.error = error;
                                    request.responseData = data;
                                    request.state = MKNKRequestStateError;
                                    return;
                                  }
                                  
                                  request.response = (NSHTTPURLResponse*) response;
                                  
                                  if(request.response.statusCode >= 200 && request.response.statusCode < 300) {
                                    
                                    request.responseData = data;
                                    request.error = error;
                                  } else if(request.response.statusCode == 304) {

                                    // don't do anything

                                  } else if(request.response.statusCode >= 400) {
                                    request.responseData = data;
                                    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
                                    if(response) userInfo[@"response"] = response;
                                    if(error) userInfo[@"error"] = error;
                                    
                                    NSError *httpError = [NSError errorWithDomain:@"com.mknetworkkit.httperrordomain"
                                                                             code:request.response.statusCode
                                                                         userInfo:userInfo];
                                    request.error = httpError;
                                    
                                    // if subclass of host overrides errorForRequest: they can provide more insightful error objects by parsing the response body.
                                    // the super class implementation just returns the same error object set in previous line
                                    request.error = [self errorForCompletedRequest:request];
                                  }
                                  
                                  if(!request.error) {
                                    
                                    if(request.cacheable) {
                                      self.dataCache[@(request.hash)] = data;
                                      self.responseCache[@(request.hash)] = response;
                                    }
                                    
                                    dispatch_sync(self.runningTasksSynchronizingQueue, ^{
                                      [self.activeTasks removeObject:request];
                                    });
                                    
                                    request.state = MKNKRequestStateCompleted;
                                  } else {
                                    
                                    dispatch_sync(self.runningTasksSynchronizingQueue, ^{
                                      [self.activeTasks removeObject:request];
                                    });
                                    request.state = MKNKRequestStateError;
                                    NSLog(@"%@", request);
                                  }
                                }];
  
  request.task = task;
  
  dispatch_sync(self.runningTasksSynchronizingQueue, ^{
    [self.activeTasks addObject:request];
  });
  
  request.state = MKNKRequestStateStarted;
  
  if(request.cacheable && !ignoreCache) {
    
    NSHTTPURLResponse *cachedResponse = self.responseCache[@(request.hash)];
    NSDate *cacheExpiryDate = cachedResponse.cacheExpiryDate;
    NSTimeInterval expiryTimeFromNow = [cacheExpiryDate timeIntervalSinceNow];
    
    if(cachedResponse.isContentTypeImage && !cacheExpiryDate) {
      
      expiryTimeFromNow =
      cachedResponse.hasRequiredRevalidationHeaders ? kMKNKDefaultCacheDuration : kMKNKDefaultImageCacheDuration;
    }
    
    if(cachedResponse.hasDoNotCacheDirective || !cachedResponse.hasHTTPCacheHeaders) {
      
      expiryTimeFromNow = kMKNKDefaultCacheDuration;
    }
    
    NSData *cachedData = self.dataCache[@(request.hash)];
    
    if(cachedData) {
      request.responseData = cachedData;
      request.response = cachedResponse;
      
      if(expiryTimeFromNow > 0 && !forceReload) {
        
        request.state = MKNKRequestStateResponseAvailableFromCache;
        return; // don't make another request
      } else {
        
        request.state = expiryTimeFromNow > 0 ? MKNKRequestStateResponseAvailableFromCache :
        MKNKRequestStateStaleResponseAvailableFromCache;
      }
    }
  }  
}

-(MKNetworkRequest*) requestWithURLString:(NSString*) urlString {
  
  MKNetworkRequest *request = [[MKNetworkRequest alloc] initWithURLString:urlString
                                                                   params:nil
                                                                 bodyData:nil
                                                               httpMethod:@"GET"];
  [self prepareRequest:request];
  return request;
}

-(MKNetworkRequest*) requestWithPath:(NSString*) path {
  
  return [self requestWithPath:path params:nil httpMethod:@"GET" body:nil ssl:self.secureHost];
}

-(MKNetworkRequest*) requestWithPath:(NSString*) path params:(NSDictionary*) params {
  
  return [self requestWithPath:path params:params httpMethod:@"GET" body:nil ssl:self.secureHost];
}

-(MKNetworkRequest*) requestWithPath:(NSString*) path
                              params:(NSDictionary*) params
                          httpMethod:(NSString*) httpMethod {
  
  return [self requestWithPath:path params:params httpMethod:httpMethod body:nil ssl:self.secureHost];
}

-(MKNetworkRequest*) requestWithPath:(NSString*) path
                              params:(NSDictionary*) params
                          httpMethod:(NSString*) httpMethod
                                body:(NSData*) bodyData
                                 ssl:(BOOL) useSSL {
  
  if(self.hostName == nil) {
    
    NSLog(@"Hostname is nil, use requestWithURLString: method to create absolute URL operations");
    return nil;
  }
  
  NSMutableString *urlString = [NSMutableString stringWithFormat:@"%@://%@",
                                useSSL ? @"https" : @"http",
                                self.hostName];
  
  if(self.portNumber != 0)
    [urlString appendFormat:@":%lu", (unsigned long)self.portNumber];
  
  if(self.path)
    [urlString appendFormat:@"/%@", self.path];
  
  if(![path isEqualToString:@"/"]) { // fetch for root?
    
    if(path.length > 0 && [path characterAtIndex:0] == '/') // if user passes /, don't prefix a slash
      [urlString appendFormat:@"%@", path];
    else if (path != nil)
      [urlString appendFormat:@"/%@", path];
  }
  
  MKNetworkRequest *request = [[MKNetworkRequest alloc] initWithURLString:urlString
                                                                   params:params
                                                                 bodyData:bodyData
                                                               httpMethod:httpMethod.uppercaseString];
  
  request.parameterEncoding = self.defaultParameterEncoding;
  [request addHeaders:self.defaultHeaders];
  [self prepareRequest:request];
  return request;
}

// You can override this method to tweak request creation
// But ensure that you call super
-(void) prepareRequest: (MKNetworkRequest*) request {
  
  if(!request.cacheable) return;
  NSHTTPURLResponse *cachedResponse = self.responseCache[@(request.hash)];
  
  NSString *lastModified = [cachedResponse.allHeaderFields objectForCaseInsensitiveKey:@"Last-Modified"];
  NSString *eTag = [cachedResponse.allHeaderFields objectForCaseInsensitiveKey:@"ETag"];
  
  if(lastModified) [request addHeaders:@{@"IF-MODIFIED-SINCE" : lastModified}];
  if(eTag) [request addHeaders:@{@"IF-NONE-MATCH" : eTag}];
}

-(NSError*) errorForCompletedRequest: (MKNetworkRequest*) completedRequest {
  
  // to be overridden by subclasses to tweak error objects by parsing the response body
  return completedRequest.error;
}

#pragma mark -
#pragma mark NSURLSession Authentication delegates

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
  
  if([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]){

    NSURLCredential *credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
    completionHandler(NSURLSessionAuthChallengeUseCredential,credential);
  }
  
  __block MKNetworkRequest *matchingRequest = nil;
  [self.activeTasks enumerateObjectsUsingBlock:^(MKNetworkRequest *request, NSUInteger idx, BOOL *stop) {
    
    if([request.task isEqual:task]) {
      matchingRequest = request;
      *stop = YES;
    }
  }];
  
  if([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic] ||
     [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPDigest]){
    
    if([challenge previousFailureCount] == 3) {
      completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
    } else {
      NSURLCredential *credential = [NSURLCredential credentialWithUser:matchingRequest.username
                                                               password:matchingRequest.password
                                                            persistence:NSURLCredentialPersistenceNone];
      if(credential) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
      } else {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
      }
    }
  }
}

#pragma mark -
#pragma mark NSURLSession (Download/Upload) Progress notification delegates

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
  
  __block MKNetworkRequest *matchingRequest = nil;
  [self.activeTasks enumerateObjectsUsingBlock:^(MKNetworkRequest *request, NSUInteger idx, BOOL *stop) {
    
    if([request.task isEqual:task]) {
      
      request.responseData = nil;
      request.response = (NSHTTPURLResponse*) task.response;
      request.error = error;
      if(error) {
        request.state = MKNKRequestStateError;
      } else {
        request.state = MKNKRequestStateCompleted;
      }
      *stop = YES;
    }
  }];
  
  dispatch_sync(self.runningTasksSynchronizingQueue, ^{
    [self.activeTasks removeObject:matchingRequest];
  });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
  
  float progress = (float)(((float)totalBytesSent) / ((float)totalBytesExpectedToSend));
  [self.activeTasks enumerateObjectsUsingBlock:^(MKNetworkRequest *request, NSUInteger idx, BOOL *stop) {
    
    if([request.task isEqual:task]) {
      [request setProgressValue:progress];
      *stop = YES;
    }
  }];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
  
  [self.activeTasks enumerateObjectsUsingBlock:^(MKNetworkRequest *request, NSUInteger idx, BOOL *stop) {
    
    if([request.task.currentRequest.URL.absoluteString isEqualToString:downloadTask.currentRequest.URL.absoluteString]) {

      NSError *error = nil;
      if(![[NSFileManager defaultManager] moveItemAtPath:location.path toPath:request.downloadPath error:&error]) {

        NSLog(@"Failed to save downloaded file at requested path [%@] with error %@", request.downloadPath, error);
      }
      
      *stop = YES;
    }
  }];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
  
  float progress = (float)(((float)totalBytesWritten) / ((float)totalBytesExpectedToWrite));  
  [self.activeTasks enumerateObjectsUsingBlock:^(MKNetworkRequest *request, NSUInteger idx, BOOL *stop) {
    
    if([request.task.currentRequest.URL.absoluteString isEqualToString:downloadTask.currentRequest.URL.absoluteString]) {
      [request setProgressValue:progress];
    }
  }];
}

@end
