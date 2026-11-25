//
//  UMMPDeltaT1Controller.h — "UMMPerfusion ΔT1 & Tumour Burden" window, added in the IsiX port.
//
//   1. ΔT1 map from a pre- and a post-contrast 3D T1 (post aligned onto pre, shading corrected)
//   2. Enhancing volume inside the ROIs you draw (on the ΔT1 map or on the pre/post series)
//   3. Fractional tumour burden: the enhancing voxels classified by the rCBV / sRCBV map
//      (sampled in scanner coordinates) as low, intermediate or high blood volume
//   4. Follow-up: the measurements of a patient over time, change from baseline and from nadir
//

#import <Cocoa/Cocoa.h>

@class UMMPerfusionFilter;

@interface UMMPDeltaT1Controller : NSWindowController <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>

+ (UMMPDeltaT1Controller *)sharedController;
- (void)showWithFilter:(UMMPerfusionFilter *)filter;

@end
