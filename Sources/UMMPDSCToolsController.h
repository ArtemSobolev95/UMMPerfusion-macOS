//
//  UMMPDSCToolsController.h — "UMMPerfusion DSC Tools" window, added in the IsiX port.
//
//  Opened from its own menu item, on the frontmost viewer:
//   - options of the DSC extensions (UMMPDSCEngine) for the next Fast Deconvolution run
//   - ROI statistics of a map (pixels marked -1 excluded), normalisation to a reference ROI
//     (e.g. contralateral NAWM → rCBV / rCBF maps), CSV export
//   - AIF check of an arterial ROI and an automatic search for AIF voxels (4D series)
//

#import <Cocoa/Cocoa.h>

@class ViewerController;
@class UMMPerfusionFilter;

@interface UMMPDSCToolsController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>

+ (UMMPDSCToolsController *)sharedController;
- (void)showForViewer:(ViewerController *)viewer filter:(UMMPerfusionFilter *)filter;

@end
