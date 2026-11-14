# Regen Settings

Throttle-release regenerative braking for the ADC1 throttle, with its own **Regen Settings** page in AppUI.

## How it works

Regen starts when **all** of these are true:

- The throttle is below the **Release Threshold**
- It has stayed released for the **Release Delay**
- Speed is above **Minimum Regen Speed + Speed Hysteresis**

Regen stops **instantly** when the throttle goes above the threshold + 3 %, the speed drops below **Minimum Regen Speed**, a motor fault occurs, or the throttle voltage leaves its valid range.

## Settings

| Setting | Range | Default |
|---|---|---|
| Enable | on / off | on |
| Regen Current | 0 - Motor Current Min | 10 A |
| Minimum Regen Speed | 1 - 60 km/h | 8 km/h |
| Throttle Release Threshold | 1 - 20 % | 5 % |
| Release Delay | 50 - 2000 ms | 300 ms |
| Speed Hysteresis | 0.5 - 10 km/h | 1.5 km/h |
| Regen Ramp-In Time | 0 - 2000 ms | 400 ms |

Press **Write** to apply. Values take effect immediately and are saved to flash as soon as the vehicle is stopped.

## Requirements

- Firmware 6.05 or newer
- App to use: ADC, ADC + UART or ADC + PAS, standard throttle on ADC1 (not a center/reverse mode)
- Correct wheel diameter, motor poles and gear ratio (for speed)

## Safety

Test on a stand first and start with a low regen current. Battery regen is always limited by **Battery Current Min** in the motor configuration.
