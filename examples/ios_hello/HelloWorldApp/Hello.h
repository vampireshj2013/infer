//
//  Hello.h
//  HelloWorldApp
//

#import <Foundation/Foundation.h>

@interface Hello : NSObject

@property (strong) NSString* s;
@property (strong) Hello* hello;

-(Hello*) return_hello;

-(NSString*) null_dereference_bug;

-(NSString*) ivar_not_nullable_bug:(Hello*) hello;

-(NSString*) parameter_not_null_checked_bug:(Hello*) hello;

@end