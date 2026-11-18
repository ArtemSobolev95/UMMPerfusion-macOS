//
//  UMMPCurvesController.h — "UMMPerfusion Time Curves" window, added in the IsiX port.
//
//  Time curves of every ROI of a 4D series, measured on the ROI's slice in every frame, overlaid
//  in one chart: signal, relative enhancement, signal difference or ΔR2*·TE. Semi-quantitative
//  parameters per curve (peak, time to peak, wash-in, wash-out, area, shape), CSV export.
//  Updates when ROIs are added, changed or removed.
//

#import <Cocoa/Cocoa.h>

@class ViewerController;

@interface UMMPCurvesController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>

+ (UMMPCurvesController *)sharedController;
- (void)showForViewer:(ViewerController *)viewer;

@end
