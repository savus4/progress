# iPad sheet layouts

Settings and Video Creator use SwiftUI's `.presentationSizing(.page)` to give
their longer forms more room on iPad. Smaller windows keep the system's compact
sheet presentation.

`AdaptiveSheetForm` arranges related sections in two columns when the sheet has
a regular horizontal size class and at least 700 points of available width.
It uses the sheet's own geometry, so a narrow multitasking window still gets one
scrolling form. Accessibility text sizes also use one column to give labels and
controls more room. Both columns scroll independently when needed.

Settings owns its child sheet presentations outside the adaptive form so changing
the column layout doesn't dismiss an open timeline editor or tip sheet.

Video Creator keeps its summary and export actions outside the scrolling form.
The action area can grow to 720 points wide, and text buttons use minimum heights
so wrapped labels can increase their height. Quality has its own section beside
the photo selection in the wide layout.

The view files include fixed-size previews for the wide settings sheet, wide and
narrow video sheets, and video settings with accessibility text.

## Runtime verification

Verified on the iPad Pro 13-inch (M5) simulator running iPadOS 27.0 on
October 30, 2026. Portrait and landscape checks passed for Settings and Video
Creator, including column placement and visibility of the camera toggle, photo
selection, quality picker, and create action. Full-resolution screenshots were
captured in both orientations. Narrow windows and accessibility text sizes have
previews; those configurations were not included in this runtime check.

## Apple guidance

- [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets):
  prefer page or form sheets on iPad; choose a presentation suited to the task.
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout):
  adapt to window size, multitasking, size classes, and Dynamic Type rather than
  choosing layouts from device type or orientation.
- [PresentationSizing](https://developer.apple.com/documentation/swiftui/presentationsizing):
  the built-in form and page sizes adapt to the device and available screen space.

Keep smaller editors and confirmation sheets focused on their content rather than
giving every modal the same large presentation.
