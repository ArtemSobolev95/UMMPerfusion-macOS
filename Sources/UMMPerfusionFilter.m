//
//  UMMPerfusionFilter.m
//  UMMPerfusion
//
//  Copyright (c) 2012, Marcel Reich & Sven Kaiser & Markus Daab & Patrick Schülein & Engin Aslan
//  All rights reserved.
//

#import "UMMPerfusionFilter.h"
#import "UMMPPanelController.h"
#import <OsiriXAPI/Notifications.h>
//#import <OsiriXAPI/AppController.h>
#import "UMMPUserDefaults.h"
#import "UMMPDSCToolsController.h"
#import "UMMPCurvesController.h"
#import "UMMPDeltaT1Controller.h"

@implementation UMMPerfusionFilter

- (void) initPlugin
{
    
}


- (long) filterImage:(NSString*) menuName
{
    // IsiX port: second menu item, works on any viewer (maps or the 4D series)
    if ([menuName isEqualToString:@"UMMPerfusion Time Curves"]) {
        [[UMMPCurvesController sharedController] showForViewer:viewerController];
        return 0;
    }
    if ([menuName isEqualToString:@"UMMPerfusion \u0394T1 & Tumour Burden"]) {   // \u0394 = Greek capital delta
        [[UMMPDeltaT1Controller sharedController] showWithFilter:self];
        return 0;
    }
    if ([menuName isEqualToString:@"UMMPerfusion DSC Tools"]) {
        [[UMMPDSCToolsController sharedController] showForViewer:viewerController filter:self];
        return 0;
    }
    
    
    NSString *osirixVersion = [[[NSBundle bundleForClass:[viewerController class]] infoDictionary] valueForKey:@"CFBundleShortVersionString"];
    
    // test auf 4D Daten, Fkt isDataVolumicIn4D funktioniert nicht richtig , speziell mit unterschiedlicher Schichtorientierung und OsiriX > 4.0
	if ([viewerController maxMovieIndex] <= 1) { /* Check for 4D-Viewer */
		NSRunAlertPanel(@"Invalid Viewer", @"This Plugin is designed for working with a 4D-Viewer.",@"OK", nil,nil);
        //[userDefaults release]; userDefaults = NULL;
		return -1;
    }
    
    // initializing user defaults in extra plist
	UMMPUserDefaults *userDefaults = [[UMMPUserDefaults alloc] init];
    
    // IsiX/Horos port: the original compared a substring of -operatingSystemVersionString with
    // 10.8.4. That string is localised, so on a Mac in another language (e.g. Russian) it read
    // "5.8.3" and refused to run. The plugin binary itself requires macOS 11 (Horos build) or
    // 15 (IsiX build), so no check is needed here.
	
	// supported OsiriX versions -> 5.6
	if (0) // IsiX port: popup removed (it compared the host with OsiriX 5.9)
		NSRunAlertPanel(@"Unsupported Osirix version", [NSString stringWithFormat:@"This Plugin has not been tested with your version of OsiriX(%@). \nUse this version at your own risk.", osirixVersion], @"OK", nil, nil);
	
    id wait = [viewerController startWaitWindow:@"Loading contents..."];
    
	[viewerController setROIToolTag:tOval]; // Usual oval ROITool used
	panel = [[UMMPPanelController alloc] initWithFilter:self andViewer:viewerController];
    [viewerController endWaitWindow:wait];
	[userDefaults release]; userDefaults=NULL;
	return 0;
}

// IsiX/Horos port: toolbar buttons. Info.plist (allowToolbarIcon) makes the host offer one toolbar
// item per menu title, all with the same icon (UMMP-icon.png). Here the two secondary items get
// their own icons; the host still runs them through -[ViewerController executeFilterFromToolbar:].
- (NSToolbarItem*) toolbarItemForItemIdentifier:(NSString*) identifier forViewer:(id) controller
{
    NSString *iconName = nil;
    if ([identifier isEqualToString:@"UMMPerfusion DSC Tools"]) iconName = @"UMMP-DSC-icon";
    else if ([identifier isEqualToString:@"UMMPerfusion Time Curves"]) iconName = @"UMMP-Curves-icon";
    if (!iconName || !controller || ![controller respondsToSelector:@selector(executeFilterFromToolbar:)])
        return nil;
    NSString *path = [[NSBundle bundleForClass:[self class]] pathForImageResource:iconName];
    NSImage *image = path ? [[[NSImage alloc] initWithContentsOfFile:path] autorelease] : nil;
    if (!image) return nil;
    NSToolbarItem *item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
    [item setLabel:identifier];
    [item setPaletteLabel:identifier];
    [item setToolTip:identifier];
    [item setImage:image];
    [item setTarget:controller];
    [item setAction:@selector(executeFilterFromToolbar:)];
    return item;
}

/* Method by Andreas Klein @ Aycan 2011-08-02 */
- (ViewerController*) duplicateViewer:(ViewerController *)vc deleteROIs:(BOOL)deleteROIs
{
	long							i;
	NSInteger						x, y, z;
	ViewerController				*new2DViewer;
	unsigned char					*fVolumePtr;
	
	// We will read our current series, and duplicate it by creating a new series!
	
	// First calculate the amount of memory needed for the new serie
	NSArray		*pixList = [vc pixList];
	DCMPix		*curPix;
	long		mem = 0;
	
	for( i = 0; i < [pixList count]; i++)
	{
		curPix = [pixList objectAtIndex: i];
		mem += [curPix pheight] * [curPix pwidth] * 4;		// each pixel contains either a 32-bit float or a 32-bit ARGB value
	}
	
	fVolumePtr = malloc( mem);	// ALWAYS use malloc for allocating memory !
	if( fVolumePtr)
	{
		// Copy the source series in the new one !
		memcpy( fVolumePtr, [vc volumePtr], mem);
		
		// Create a NSData object to control the new pointer
		NSData		*volumeData = [[[NSData alloc] initWithBytesNoCopy:fVolumePtr length:mem freeWhenDone:YES] autorelease];
		
		// Now copy the DCMPix with the new fVolumePtr
		NSMutableArray *newPixList = [NSMutableArray arrayWithCapacity:0];
		for( i = 0; i < [pixList count]; i++)
		{
			curPix = [[[pixList objectAtIndex: i] copy] autorelease];
			[curPix setfImage: (float*) (fVolumePtr + [curPix pheight] * [curPix pwidth] * 4 * i)];
			[newPixList addObject: curPix];
		}
		
		// We don't need to duplicate the DicomFile array, because it is identical!
		
		// A 2D Viewer window needs 3 things:
		// A mutable array composed of DCMPix objects
		// A mutable array composed of DicomFile objects
		// Number of DCMPix and DicomFile has to be EQUAL !
		// NSData volumeData contains the images, represented in the DCMPix objects
		new2DViewer = [vc newWindow:newPixList :[vc fileList] :volumeData];
		
		//[new2DViewer roiDeleteAll:self];
		[new2DViewer addToUndoQueue: @"roi"];
		
		if (deleteROIs) {
			DCMView *imageView = [new2DViewer imageView];
			[imageView stopROIEditingForce: YES];
			
			for( y = 0; y < [new2DViewer maxMovieIndex]; y++)
			{
				NSMutableArray *pixList = [new2DViewer pixList:y];
				NSMutableArray *roiList = [new2DViewer roiList:y];
				
				for( x = 0; x < [pixList count]; x++)
				{
					for( z = [roiList count]-1; z >= 0 ; z--)
					{
						ROI *curROI = [roiList objectAtIndex:z];
						
						if(curROI.locked == NO)
						{
							[[NSNotificationCenter defaultCenter] postNotificationName: OsirixRemoveROINotification object:curROI userInfo: nil];
							[roiList removeObject: curROI];
						}
					}
				}
			}
			
			[imageView setIndex: [imageView curImage]];
		}
		return new2DViewer;
	}
	
	return nil;
}

@end
