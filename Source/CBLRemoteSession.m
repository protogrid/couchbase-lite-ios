//
//  CBLRemoteSession.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 2/4/16.
//  Copyright © 2016 Couchbase, Inc. All rights reserved.
//

#import "CBLRemoteSession.h"
#import "CBLRemoteRequest.h"
#import "CBL_ReplicatorSettings.h"
#import "CBLCookieStorage.h"


@interface CBLRemoteSession () <NSURLSessionDataDelegate>
@end


@implementation CBLRemoteSession
{
    NSURLSession* _session;
    NSRunLoop* _runLoop;
    NSMutableDictionary<NSNumber*, CBLRemoteRequest*>* _requestIDs; // Used on operation queue only
    NSMutableSet<CBLRemoteRequest*>* _allRequests;                  // Used on API thread only
    CBLCookieStorage* _cookieStorage;
}

@synthesize authorizer=_authorizer;


+ (NSURLSessionConfiguration*) defaultConfiguration {
    NSURLSessionConfiguration* config;
    config = [[NSURLSessionConfiguration defaultSessionConfiguration] copy];
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.HTTPCookieStorage = nil;
    config.HTTPShouldSetCookies = NO;
    config.URLCache = nil;
    config.HTTPAdditionalHeaders = @{@"User-Agent": [CBL_ReplicatorSettings userAgentHeader]};
    return config;
}


- (instancetype)initWithConfiguration: (NSURLSessionConfiguration*)config
                           authorizer: (id<CBLAuthorizer>)authorizer
                        cookieStorage: (CBLCookieStorage*)cookieStorage
{
    self = [super init];
    if (self) {
        _authorizer = authorizer;
        _cookieStorage = cookieStorage;
        NSOperationQueue* queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration: config
                                                 delegate: self
                                            delegateQueue: queue];
        _session.sessionDescription = @"Couchbase Lite";
        _runLoop = [NSRunLoop currentRunLoop];
        _requestIDs = [NSMutableDictionary new];
    }
    return self;
}


- (instancetype) init {
    return [self initWithConfiguration: [[self class] defaultConfiguration]
                            authorizer: nil
                         cookieStorage: nil];
}


- (void)dealloc {
    if (_allRequests.count > 0)
        Warn(@"CBLRemoteSession dealloced but has leftover requests: %@", _allRequests);
}


- (void) close {
    [_session.delegateQueue addOperationWithBlock:^{
        // Do this on the queue so that it's properly ordered with the tasks being started in
        // the -startRequest method.
        LogTo(RemoteRequest, @"CBLRemoteSession closing");
        [_session finishTasksAndInvalidate];
    }];
}


- (void) startRequest: (CBLRemoteRequest*)request {
    request.session = self;
    if (_authorizer)
        request.authorizer = _authorizer;
    request.cookieStorage = _cookieStorage;
    NSURLSessionTask* task = [request createTaskInURLSession: _session];
    if (!task)
        return;

    if (!_allRequests)
        _allRequests = [NSMutableSet new];
    [_allRequests addObject: request];

    [_session.delegateQueue addOperationWithBlock:^{
        // Now running on delegate queue:
        _requestIDs[@(task.taskIdentifier)] = request;
        LogTo(RemoteRequest, @"CBLRemoteSession starting %@", request);
        [task resume]; // Go!
    }];
}


- (NSArray<CBLRemoteRequest*>*) activeRequests {
    return _allRequests.allObjects;
}


- (void) stopActiveRequests {
    if (!_allRequests)
        return;
    LogTo(RemoteRequest, @"Stopping %u remote requests", (unsigned)_allRequests.count);
    // Clear _allRequests before iterating, to ensure that re-entrant calls to this won't
    // try to re-stop any of the requests. (Re-entrant calls are possible due to replicator
    // error handling when it receives the 'canceled' errors from the requests I'm stopping.)
    NSSet* requests = _allRequests;
    _allRequests = nil;
    [requests makeObjectsPerformSelector: @selector(stop)];
}


#pragma mark - INTERNAL:


// must be called on the delegate queue
- (void) forgetTask: (NSURLSessionTask*)task {
    [_requestIDs removeObjectForKey: @(task.taskIdentifier)];
}


- (void) requestForTask: (NSURLSessionTask*)task
                     do: (void(^)(CBLRemoteRequest*))block
{
    // This is called on the delegate queue!
    Assert(task);
    CBLRemoteRequest *request = _requestIDs[@(task.taskIdentifier)];
    if (request) {
        LogDebug(RemoteRequest, @">>> performBlock for %@", request);
        CFRunLoopPerformBlock(_runLoop.getCFRunLoop, kCFRunLoopDefaultMode, ^{
            // Now on the replicator thread
            LogDebug(RemoteRequest, @"   <<< calling block for %@", request);
            if (request.task == task) {
                block(request);
            } else {
                [_session.delegateQueue addOperationWithBlock:^{
                    [self forgetTask: task];
                }];
            }
        });
        CFRunLoopWakeUp(_runLoop.getCFRunLoop);
    }
}


#pragma mark - SESSION DELEGATE:


// NOTE: All of these methods are called on the NSURLSession queue, not the replicator thread.


- (void) URLSession:(NSURLSession *)session didBecomeInvalidWithError:(nullable NSError *)error {
    LogTo(RemoteRequest, @"CBLRemoteSession closed");
    if (_requestIDs.count > 0)
        Warn(@"CBLRemoteSession closed but has leftover tasks: %@", _requestIDs.allValues);
    _session = nil;
    _allRequests = nil;
    _requestIDs = nil;
}


- (void)URLSession:(NSURLSession *)session
        task:(NSURLSessionTask *)task
        willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)newURLRequest
        completionHandler:(void (^)(NSURLRequest * __nullable))completionHandler
{
    [self requestForTask: task do: ^(CBLRemoteRequest *request) {
        completionHandler([request willSendRequest: newURLRequest
                                  redirectResponse: response]);
    }];
}


- (void)URLSession:(NSURLSession *)session
        task:(NSURLSessionTask *)task
        didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
        completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition,
                                    NSURLCredential * __nullable credential))completionHandler
{
    [self requestForTask: task do: ^(CBLRemoteRequest *request) {
        NSURLSessionAuthChallengeDisposition disposition;
        disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        NSURLCredential* credential = nil;
        NSString* authMethod = challenge.protectionSpace.authenticationMethod;
        LogTo(RemoteRequest, @"Got challenge for %@: method=%@, err=%@",
              request, authMethod, challenge.error);
        if ($equal(authMethod, NSURLAuthenticationMethodHTTPBasic) ||
                $equal(authMethod, NSURLAuthenticationMethodHTTPDigest)) {
            // HTTP authentication:
            credential = [request credentialForHTTPAuthChallenge: challenge
                                                     disposition: &disposition];
        } else if ($equal(authMethod, NSURLAuthenticationMethodClientCertificate)) {
            // SSL client-cert authentication:
            credential = [request credentialForClientCertChallenge: challenge
                                                       disposition: &disposition];
        } else if ($equal(authMethod, NSURLAuthenticationMethodServerTrust)) {
            // Check server's SSL cert:
            SecTrustRef trust = [request checkServerTrust: challenge];
            if (trust) {
                credential = [NSURLCredential credentialForTrust: trust];
                disposition = NSURLSessionAuthChallengeUseCredential;
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            LogTo(RemoteRequest, @"    challenge: performDefaultHandling");
        }
        completionHandler(disposition, credential);
    }];
}


- (void)URLSession:(NSURLSession *)session
        task:(NSURLSessionTask *)task
        needNewBodyStream:(void (^)(NSInputStream * __nullable bodyStream))completionHandler
{
    [self requestForTask: task do: ^(CBLRemoteRequest *request) {
        completionHandler([request needNewBodyStream]);
    }];
}

- (void)URLSession:(NSURLSession *)session
        dataTask:(NSURLSessionDataTask *)dataTask
        didReceiveResponse:(NSURLResponse *)response
        completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    [self requestForTask: dataTask do: ^(CBLRemoteRequest *request) {
        [request didReceiveResponse: (NSHTTPURLResponse*)response];

        // If the request had to change its credentials to pass authentication,
        // pick up the new authorizer for later requests:
        NSInteger status = ((NSHTTPURLResponse*)response).statusCode;
        id<CBLAuthorizer> auth = request.authorizer;
        if (auth && auth != _authorizer && status != 401) {
            LogTo(RemoteRequest, @"%@: Updated to %@", self, auth);
            _authorizer = auth;
        }

        completionHandler(request.running ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
    }];
}

- (void)URLSession:(NSURLSession *)session
        dataTask:(NSURLSessionDataTask *)dataTask
        didReceiveData:(NSData *)data
{
    [self requestForTask: dataTask do: ^(CBLRemoteRequest *request) {
        if (request.running)  // request might have just canceled itself
            [request _didReceiveData: data];
    }];
}

- (void)URLSession:(NSURLSession *)session
        task:(NSURLSessionTask *)task
        didCompleteWithError:(nullable NSError *)error
{
    [self requestForTask: task do: ^(CBLRemoteRequest *request) {
        [_allRequests removeObject: request];
        if (error)
            [request didFailWithError: error];
        else
            [request _didFinishLoading];
    }];
    LogTo(RemoteRequest, @"CBLRemoteSession done with %@", _requestIDs[@(task.taskIdentifier)]);
    [self forgetTask: task];
}

- (void)URLSession:(NSURLSession *)session
        dataTask:(NSURLSessionDataTask *)dataTask
        willCacheResponse:(NSCachedURLResponse *)proposedResponse
        completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler
{
    completionHandler(nil); // no caching
}


@end
