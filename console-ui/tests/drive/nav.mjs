// The one locator the drives use for "this screen is in the app's navigation"
// (BH-9118). Every screen is a link in the side menu (src/ui/SideMenu.js);
// the phone's bottom nav holds only five of them, and the top bar holds none.
// On a phone the menu is a closed drawer, so the link is in the DOM but not
// visible until the hamburger (`MENU_BUTTON`) opens it.

export const SIDE_MENU = 'nav#sidemenu';
export const MENU_BUTTON = 'button.topbar__menu';
export const navLink = (href) => `${SIDE_MENU} a[href="${href}"]`;
