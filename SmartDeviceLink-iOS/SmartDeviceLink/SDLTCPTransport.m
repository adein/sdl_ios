//  SDLTCPTransport.m
//


#import "SDLTCPTransport.h"
#import "SDLDebugTool.h"
#import "SDLHexUtility.h"
#import <errno.h>
#import <signal.h>
#import <stdio.h>
#import <unistd.h>
#import <sys/types.h>
#import <sys/socket.h>
#import <sys/wait.h>
#import <netinet/in.h>
#import <netdb.h>


// C function forward declarations.
int call_socket(const char *hostname, const char *port);
static void TCPCallback(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);

@interface SDLTCPTransport () {
    BOOL _alreadyDestructed;
    dispatch_queue_t _sendQueue;
}

@property (strong, nonatomic) NSInputStream *inputStream;
@property (strong, nonatomic) NSOutputStream *outputStream;
@property (assign, nonatomic) BOOL connected;
@end


@implementation SDLTCPTransport

- (instancetype)init {
    if (self = [super init]) {
        _alreadyDestructed = NO;
        _sendQueue = dispatch_queue_create("com.sdl.transport.tcp.transmit", DISPATCH_QUEUE_SERIAL);
        [SDLDebugTool logInfo:@"SDLTCPTransport Init"
                     withType:SDLDebugType_Transport_iAP
                     toOutput:SDLDebugOutput_All
                      toGroup:self.debugConsoleGroupName];
        _connected = NO;
    }
    return self;
}


- (void)connect {
    [SDLDebugTool logInfo:[NSString stringWithFormat:@"InitTCP withIP:%@ withPort:%@", self.hostName, self.portNumber] withType:SDLDebugType_Transport_TCP];
    [self connectToServerWithIP:self.hostName andPort:[self.portNumber intValue]];
    /*
    int sock_fd = call_socket([self.hostName UTF8String], [self.portNumber UTF8String]);
    if (sock_fd < 0) {
        [SDLDebugTool logInfo:@"Server Not Ready, Connection Failed" withType:SDLDebugType_Transport_TCP];
        return;
    }
    
    CFSocketContext socketCtxt = {0, (__bridge void *)(self), NULL, NULL, NULL};
    socket = CFSocketCreateWithNative(kCFAllocatorDefault, sock_fd, kCFSocketDataCallBack | kCFSocketConnectCallBack, (CFSocketCallBack)&TCPCallback, &socketCtxt);
    CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0);
    CFRunLoopRef loop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(loop, source, kCFRunLoopDefaultMode);
    CFRelease(source);
    */
}

- (void)sendData:(NSData *)msgBytes {
    dispatch_async(_sendQueue, ^{
        NSString* byteStr = [SDLHexUtility getHexString:msgBytes];
        int outputBytes = (int)[self.outputStream write:[msgBytes bytes] maxLength:msgBytes.length];
        [SDLDebugTool logInfo:[NSString stringWithFormat:@"Sent %lu bytes: %@", (unsigned long)outputBytes, byteStr] withType:SDLDebugType_Transport_TCP toOutput:SDLDebugOutput_DeviceConsole];
        /*
        CFSocketError e = CFSocketSendData(socket, NULL, (__bridge CFDataRef)msgBytes, 10000);
        if (e != kCFSocketSuccess) {
            NSString *errorCause = nil;
            switch (e) {
                case kCFSocketTimeout:
                    errorCause = @"Socket Timeout Error.";
                    break;
                    
                case kCFSocketError:
                default:
                    errorCause = @"Socket Error.";
                    break;
            }
            
            [SDLDebugTool logInfo:[NSString stringWithFormat:@"Socket sendData error: %@", errorCause] withType:SDLDebugType_Transport_TCP toOutput:SDLDebugOutput_DeviceConsole];
        }
        */
    });
}

#pragma mark - NSStream Delegate methods

- (void)stream:(NSStream *)theStream handleEvent:(NSStreamEvent)streamEvent
{
    switch (streamEvent)
    {
        case NSStreamEventOpenCompleted:
            if (!self.connected)
            {
                self.connected = YES;
                [self.delegate onTransportConnected];
            }
            break;
            
        case NSStreamEventHasBytesAvailable:
            if (self.inputStream == theStream)
            {
                uint8_t buffer[1024];   //TODO: MTU related?
                int len;                   //buffer size
                NSMutableData *response = [[NSMutableData alloc] init];
                while ([self.inputStream hasBytesAvailable])
                {
                    len = (int)[self.inputStream read:buffer maxLength:sizeof(buffer)];
                    if (len > 0)[response appendBytes:buffer length:len];
                }
                [self.delegate onDataReceived:response];
            }
            break;
            
        case NSStreamEventHasSpaceAvailable:
            break;
            
        case NSStreamEventErrorOccurred:
            break;
            
        case NSStreamEventEndEncountered:
            [theStream close];
            [theStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
            break;
            
        case NSStreamEventNone:
            break;
            
        default:
    }
}

- (void)destructObjects {
    if (!_alreadyDestructed) {
        _alreadyDestructed = YES;
        if (socket != nil) {
            CFSocketInvalidate(socket);
            CFRelease(socket);
        }
    }
}

- (void)disconnect {
    [self dispose];
}

- (void)dispose {
    [self destructObjects];
}

- (void)dealloc {
    [self destructObjects];
}

- (void)connectToServerWithIP:(NSString *)ip andPort:(int)port
{
    //instantiate input and output byte streams
    CFReadStreamRef readStream;
    CFWriteStreamRef writeStream;
    
    //open socket connection
    CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, (__bridge CFStringRef)ip, port, &readStream, &writeStream);
    
    //cast C structs to Objective-C objects
    self.inputStream =  (__bridge NSInputStream *)readStream;
    self.outputStream = (__bridge NSOutputStream *)writeStream;
    
    //set NSStream delegates
    [self.inputStream setDelegate:self];
    [self.outputStream setDelegate:self];
    
    [self.inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [self.outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    
    //open byte stream communication
    [self.inputStream open];
    [self.outputStream open];
}


@end

// C functions
int call_socket(const char *hostname, const char *port) {
    int status, sock;
    struct addrinfo hints;
    struct addrinfo *servinfo;

    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    //no host name?, no problem, get local host
    if (hostname == nil) {
        char localhost[128];
        gethostname(localhost, sizeof localhost);
        hostname = (const char *)&localhost;
    }

    //getaddrinfo setup
    if ((status = getaddrinfo(hostname, port, &hints, &servinfo)) != 0) {
        fprintf(stderr, "getaddrinfo error: %s\n", gai_strerror(status));
        return (-1);
    }

    //get socket
    if ((sock = socket(servinfo->ai_family, servinfo->ai_socktype, servinfo->ai_protocol)) < 0)
        return (-1);

    //connect
    if (connect(sock, servinfo->ai_addr, servinfo->ai_addrlen) < 0) {
        close(sock);
        return (-1);
    }

    freeaddrinfo(servinfo); // free the linked-list
    return (sock);
}

static void TCPCallback(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    if (kCFSocketConnectCallBack == type) {
        SDLTCPTransport *transport = (__bridge SDLTCPTransport *)info;
        SInt32 errorNumber = 0;
        if (data) {
            SInt32 *errorNumberPtr = (SInt32 *)data;
            errorNumber = *errorNumberPtr;
        }
        [transport.delegate onTransportConnected];
    } else if (kCFSocketDataCallBack == type) {
        SDLTCPTransport *transport = (__bridge SDLTCPTransport *)info;

        NSMutableString *byteStr = [NSMutableString stringWithCapacity:((int)CFDataGetLength((CFDataRef)data) * 2)];
        for (int i = 0; i < (int)CFDataGetLength((CFDataRef)data); i++) {
            [byteStr appendFormat:@"%02X", ((Byte *)(UInt8 *)CFDataGetBytePtr((CFDataRef)data))[i]];
        }

        [SDLDebugTool logInfo:[NSString stringWithFormat:@"Read %d bytes: %@", (int)CFDataGetLength((CFDataRef)data), byteStr] withType:SDLDebugType_Transport_TCP toOutput:SDLDebugOutput_DeviceConsole];

        [transport.delegate onDataReceived:[NSData dataWithBytes:(UInt8 *)CFDataGetBytePtr((CFDataRef)data) length:(int)CFDataGetLength((CFDataRef)data)]];
    } else {
        NSString *logMessage = [NSString stringWithFormat:@"unhandled TCPCallback: %lu", type];
        [SDLDebugTool logInfo:logMessage withType:SDLDebugType_Transport_TCP toOutput:SDLDebugOutput_DeviceConsole];
    }
}
