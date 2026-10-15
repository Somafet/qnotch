import partly from '../assets/weather/partlycloudy_day.png?url';
import showers from '../assets/weather/lightrainshowers_day.png?url';
import cloudy from '../assets/weather/cloudy.png?url';
import clear from '../assets/weather/clearsky_day.png?url';

// The forecast the demo and the feature card show: Oslo, like the app's snapshot mode.
// The symbols are yr.no's (MIT, see assets/weather/LICENSE), the same files the app bundles.
export const WX = {
  place: 'Oslo',
  url: 'https://www.yr.no/en/forecast/daily-table/1-72837/Norway/Oslo/Oslo/Oslo',
  icon: partly,
  temp: '14°',
  condition: 'Partly cloudy',
  detail: 'Feels 12° · 4 m/s',
};

const DAYS = [
  [partly, '15°', '8°', 'Partly cloudy'],
  [showers, '12°', '7°', 'Light rain showers'],
  [cloudy, '11°', '6°', 'Cloudy'],
  [clear, '16°', '7°', 'Clear sky'],
] as const;

/** Name of the day i days from now, as the app shows it: Today, then Thu, Fri, Sat. */
export const wxDayName = (i: number) => i === 0 ? 'Today' : new Date(Date.now() + i * 864e5).toLocaleDateString('en-US', { weekday: 'short' });

/** Today and the next three days. */
export const wxDays = () => DAYS.map(([icon, high, low, tip], i) => ({ name: wxDayName(i), icon, high, low, tip }));
