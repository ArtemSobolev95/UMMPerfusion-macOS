//
//  UMMPUIHelpers.h — small builders for the windows made in code (IsiX port): DSC Tools,
//  ΔT1 & Tumour Burden.
//

#import <Cocoa/Cocoa.h>

static inline NSTextField *UMMPLabel(NSString *text)
{
    NSTextField *f = [NSTextField labelWithString:text];
    [f setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    return f;
}

static inline NSTextField *UMMPNumberField(NSString *value, CGFloat width)
{
    NSTextField *f = [NSTextField textFieldWithString:value];
    [f setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [f setAlignment:NSTextAlignmentRight];
    [[f widthAnchor] constraintEqualToConstant:width].active = YES;
    return f;
}

static inline NSButton *UMMPCheckbox(NSString *title, id target, SEL action)
{
    NSButton *b = [NSButton checkboxWithTitle:title target:target action:action];
    [b setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    return b;
}

static inline NSButton *UMMPButton(NSString *title, id target, SEL action)
{
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    [b setControlSize:NSControlSizeSmall];
    [b setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    return b;
}

static inline NSStackView *UMMPRow(NSArray *views)
{
    NSStackView *row = [NSStackView stackViewWithViews:views];
    [row setOrientation:NSUserInterfaceLayoutOrientationHorizontal];
    [row setAlignment:NSLayoutAttributeFirstBaseline];
    [row setSpacing:6];
    return row;
}

static inline NSBox *UMMPSection(NSString *title, NSView *content)
{
    NSBox *box = [[[NSBox alloc] init] autorelease];
    [box setTitle:title];
    [box setTitleFont:[NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]]];
    [box setContentViewMargins:NSMakeSize(8, 8)];
    [content setTranslatesAutoresizingMaskIntoConstraints:NO];
    [[box contentView] addSubview:content];
    NSView *cv = [box contentView];
    [NSLayoutConstraint activateConstraints:@[
        [[content leadingAnchor] constraintEqualToAnchor:[cv leadingAnchor] constant:8],
        [[content trailingAnchor] constraintEqualToAnchor:[cv trailingAnchor] constant:-8],
        [[content topAnchor] constraintEqualToAnchor:[cv topAnchor] constant:6],
        [[content bottomAnchor] constraintEqualToAnchor:[cv bottomAnchor] constant:-8]]];
    return box;
}
