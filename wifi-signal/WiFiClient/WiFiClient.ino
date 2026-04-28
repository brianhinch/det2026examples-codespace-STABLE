/*
  WiFiClient.ino — Connect to a WiFi network and report signal quality.
  Target: Adafruit ESP32 Feather v2

  Disconnected: retries every 5 s (only on terminal failure); NeoPixel flashes red/off at 1 Hz.
  Connected:    prints RSSI, estimated noise floor, and SNR to Serial every
                second; sets NeoPixel color based on SNR:
                  hue gradient: red → yellow → green → white over 0–40 dB
                  brightness: log scale, 0 dB = off, 40 dB = full

  Note: ESP32 does not expose a hardware noise floor API. SNR is estimated
  using RSSI minus a typical 2.4 GHz ambient noise floor of -95 dBm.
*/

#include <Arduino.h>
#include <WiFi.h>
#include <Adafruit_NeoPixel.h>

const char *SSID     = "testAP1";
const char *PASSWORD = "password1234";

static const int NOISE_FLOOR_DBM = -95;
static const int SW38_PIN        = 38;
static const int BRIGHTNESS      = 255;

Adafruit_NeoPixel pixel(1, PIN_NEOPIXEL, NEO_GRB + NEO_KHZ800);

uint32_t snrToColorQuantize(float snr) {
  // if (snr < 15.0f) {                                      // red
  //   return pixel.Color(255, 0, 0);
  // }
  // if (snr < 25.0f) {                                      // yellow
  //   return pixel.Color(255, 255, 0);
  // }
  if (snr < 25.0f) {                                      // red
    return pixel.Color(255, 0, 0);
  }
  if (snr < 40.0f) {                                      // green
    return pixel.Color(0, 255, 0);
  }
  return pixel.Color(255, 255, 255);
}

// < 15 dB: solid red. 15–40 dB: smooth gradient red→yellow→green→white.
uint32_t snrToColorSmooth(float snr) {
  if (snr < 15.0f) return pixel.Color(255, 0, 0);

  if (snr < 20.0f) {                                      // red → yellow
    float t = (snr - 15.0f) / 5.0f;
    return pixel.Color(255, (uint8_t)(255 * t), 0);
  }
  if (snr < 25.0f) {                                      // yellow → green
    float t = (snr - 20.0f) / 5.0f;
    return pixel.Color((uint8_t)(255 * (1.0f - t)), 255, 0);
  }
  if (snr < 40.0f) {                                      // green → white
    float t = (snr - 25.0f) / 15.0f;
    return pixel.Color((uint8_t)(255 * t), 255, (uint8_t)(255 * t));
  }
  return pixel.Color(255, 255, 255);
}

void setup() {
  Serial.begin(115200);

#ifdef NEOPIXEL_POWER
  pinMode(NEOPIXEL_POWER, OUTPUT);
  digitalWrite(NEOPIXEL_POWER, HIGH);
#endif

  pixel.begin();
  // pixel.clear();
  pixel.setBrightness(BRIGHTNESS);
  pixel.show();

  pinMode(SW38_PIN, INPUT);  // input-only pin, external pull-up on Feather V2

  WiFi.mode(WIFI_STA);
  Serial.printf("Connecting to \"%s\"...\n", SSID);
  WiFi.begin(SSID, PASSWORD);
}

void loop() {
  static unsigned long lastToggle  = 0;
  static unsigned long lastRetry   = 0;
  static unsigned long lastReport  = 0;
  static unsigned long lastSerial  = 0;
  static bool          pixelOn     = false;
  static uint32_t      currentColor = 0;

  unsigned long now = millis();

  if (WiFi.status() != WL_CONNECTED) {
    if (now - lastToggle >= 500) {
      lastToggle = now;
      pixelOn = !pixelOn;
      currentColor = pixelOn ? pixel.Color(255, 0, 0) : 0;
    }

    // Only retry on terminal failure states; 5 s gives DHCP time to complete.
    // WL_IDLE_STATUS means a connection attempt is in progress — don't interrupt it.
    if (now - lastRetry >= 5000) {
      lastRetry = now;
      wl_status_t s = WiFi.status();
      Serial.printf("WiFi status: %d  ", s);
      if (s == WL_DISCONNECTED || s == WL_CONNECT_FAILED || s == WL_CONNECTION_LOST) {
        Serial.printf("— retrying \"%s\"...\n", SSID);
        WiFi.begin(SSID, PASSWORD);
      } else {
        Serial.println("— waiting for connection...");
      }
    }

  } else {
    if (now - lastReport >= 50) {
      lastReport = now;
      int32_t rssi = WiFi.RSSI();
      float   snr  = (float)(rssi - NOISE_FLOOR_DBM);
      currentColor = snrToColorQuantize(snr);

      if (now - lastSerial >= 500) {
        lastSerial = now;
        Serial.printf("RSSI: %d dBm  |  Noise (est): %d dBm  |  SNR: %.1f dB\n",
                      rssi, NOISE_FLOOR_DBM, snr);
      }
    }
  }

  pixel.setPixelColor(0, digitalRead(SW38_PIN) == LOW ? 0 : currentColor);
  pixel.show();
}
