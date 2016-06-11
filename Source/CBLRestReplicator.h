//
//  CBLRestReplicator.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 12/6/11.
//  Copyright (c) 2011-2013 Couchbase, Inc. All rights reserved.
//

#import "CBL_Replicator.h"

@class CBLBatcher, CBLRemoteRequest, MYBackgroundMonitor;


/** Abstract base class for push or pull replications. */
@interface CBLRestReplicator : NSObject <CBL_Replicator>
{
    @protected
    CBL_ReplicatorSettings* _settings;
    CBLDatabase* __weak _db;
    NSString* _lastSequence;
    CBLBatcher* _batcher;
    NSString* _serverType;
#if TARGET_OS_IPHONE
    MYBackgroundMonitor *_bgMonitor;
#endif
}

#if DEBUG
@property (readonly) BOOL running, active; // for unit tests
#endif

- (void) startRemoteRequest: (CBLRemoteRequest*)request;

@end
