//  SDLTCPTransport.h
//

#import "SDLAbstractTransport.h"

@interface SDLTCPTransport : SDLAbstractTransport<NSStreamDelegate> {
    CFSocketRef socket;
}

@property (strong, atomic) NSString *hostName;
@property (strong, atomic) NSString *portNumber;

@end
