#Author: Benjamin Pyatski
#Company: Chory Lab

import sys
import time
import RPi.GPIO as GPIO
import redis

GPIO.setmode(GPIO.BCM)

string_to_bool = {'True':True, 'False': False, None: None}

# Limit switches, one at each end of the rail. Each is wired COM -> GND and
# NC -> GPIO (see README), so it reads LOW while closed and HIGH once the
# striker opens it. A broken or unplugged wire also reads HIGH, so it stops
# the cart instead of letting it drive into the end of the rail.
LIMIT_RIGHT_PIN = 17  # Hamilton end, reached by clockwise (go_right) moves
LIMIT_LEFT_PIN = 4    # incubator end, reached by counter-clockwise (go_left) moves
LIMIT_PIN = {True: LIMIT_RIGHT_PIN, False: LIMIT_LEFT_PIN}

# A press must read HIGH this many times in a row, this far apart, so a
# noise spike from the motor wiring can't end a move early.
LIMIT_CONFIRM_READS = 3
LIMIT_CONFIRM_INTERVAL = 0.001  # seconds

for _pin in (LIMIT_LEFT_PIN, LIMIT_RIGHT_PIN):
    GPIO.setup(_pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)

# How a move ended, as returned by A4988Nema.motor_go
LIMIT = 'limit'                # the switch in the direction of travel was hit
COMPLETED = 'completed'        # every requested step ran without hitting it
STOPPED = 'stopped'            # Stop Motor or Ctrl-C
SWITCH_FAULT = 'switch_fault'  # both switches read pressed: a wiring fault
ERROR = 'error'                # unexpected exception


def at_limit(pin):
    """ True when the limit switch on `pin` is pressed (or its wire is broken) """
    for _ in range(LIMIT_CONFIRM_READS):
        if GPIO.input(pin) != GPIO.HIGH:
            return False
        time.sleep(LIMIT_CONFIRM_INTERVAL)
    return True

class StopMotorInterrupt(Exception):
    """ Stop the motor """
    pass

class A4988Nema(object):
    """ Class to control a Nema bi-polar stepper motor with a A4988 also tested with DRV8825"""
    def __init__(self, direction_pin, step_pin, mode_pins, motor_type, cache):
        """ class init method 3 inputs
        (1) direction type=int , help=GPIO pin connected to DIR pin of IC
        (2) step_pin type=int , help=GPIO pin connected to STEP of IC
        (3) mode_pins type=tuple of 3 ints, help=GPIO pins connected to
        Microstep Resolution pins MS1-MS3 of IC, can be set to (-1,-1,-1) to turn off
        GPIO resolution.
        (4) motor_type type=string, help=Type of motor two options: A4988 or DRV8825
        """
        self.motor_type = motor_type
        self.direction_pin = direction_pin
        self.step_pin = step_pin
        self.cache = cache

        if mode_pins[0] != -1:
            self.mode_pins = mode_pins
        else:
            self.mode_pins = False

        self.stop_motor = False
        GPIO.setwarnings(False)

    def motor_stop(self):
        """ Stop the motor """
        self.stop_motor = True

    def resolution_set(self, steptype):
        """ method to calculate step resolution
        based on motor type and steptype"""
        if self.motor_type == "A4988":
            resolution = {'Full': (0, 0, 0),
                          'Half': (1, 0, 0),
                          '1/4': (0, 1, 0),
                          '1/8': (1, 1, 0),
                          '1/16': (1, 1, 1)}
        elif self.motor_type == "DRV8825":
            resolution = {'Full': (0, 0, 0),
                          'Half': (1, 0, 0),
                          '1/4': (0, 1, 0),
                          '1/8': (1, 1, 0),
                          '1/16': (0, 0, 1),
                          '1/32': (1, 0, 1)}
        elif self.motor_type == "LV8729":
            resolution = {'Full': (0, 0, 0),
                          'Half': (1, 0, 0),
                          '1/4': (0, 1, 0),
                          '1/8': (1, 1, 0),
                          '1/16': (0, 0, 1),
                          '1/32': (1, 0, 1),
                          '1/64': (0, 1, 1),
                          '1/128': (1, 1, 1)}
        else:
            print("Error invalid motor_type: {}".format(self.motor_type))
            quit()

        # error check stepmode
        if steptype in resolution:
            pass
        else:
            print("Error invalid steptype: {}".format(steptype))
            quit()

        if self.mode_pins != False:
            GPIO.output(self.mode_pins, resolution[steptype])

    def motor_go(self, clockwise=False, steptype="Full",
                 steps=200, stepdelay=.005, verbose=False, initdelay=.05):
        """ motor_go,  moves stepper motor based on 6 inputs

         (1) clockwise, type=bool default=False
         help="Turn stepper counterclockwise"
         (2) steptype, type=string , default=Full help= type of drive to
         step motor 5 options
            (Full, Half, 1/4, 1/8, 1/16) 1/32 for DRV8825 only 1/64 1/128 for LV8729 only
         (3) steps, type=int, default=200, help=Number of steps sequence's
         to execute. Default is one revolution , 200 in Full mode.
         (4) stepdelay, type=float, default=0.05, help=Time to wait
         (in seconds) between steps.
         (5) verbose, type=bool  type=bool default=False
         help="Write pin actions",
         (6) initdelay, type=float, default=1mS, help= Intial delay after
         GPIO pins initialized but before motor is moved.

         The move ends early when the limit switch at the end the motor is
         heading toward is pressed. The switch at the other end is ignored,
         so the cart can always drive away from it.

         Returns (result, steps_taken), where result is one of LIMIT,
         COMPLETED, STOPPED, SWITCH_FAULT or ERROR.
        """
        limit_pin = LIMIT_PIN[bool(clockwise)]
        result = ERROR
        steps_taken = 0

        # setup GPIO
        GPIO.setup(self.direction_pin, GPIO.OUT)
        GPIO.setup(self.step_pin, GPIO.OUT)
        GPIO.output(self.direction_pin, clockwise)
        if self.mode_pins != False:
            GPIO.setup(self.mode_pins, GPIO.OUT)

        try:
            # dict resolution
            self.resolution_set(steptype)

            # Only a wiring fault can press both ends at once
            if at_limit(LIMIT_LEFT_PIN) and at_limit(LIMIT_RIGHT_PIN):
                print("Both limit switches read pressed: check the switch wiring")
                result = SWITCH_FAULT
                return result, steps_taken

            time.sleep(initdelay)

            result = COMPLETED
            for i in range(steps):
                if string_to_bool[self.cache.get('motor_stop')]:
                    self.cache.set('motor_stop', 'False')
                    raise StopMotorInterrupt

                if at_limit(limit_pin):
                    result = LIMIT
                    break

                GPIO.output(self.step_pin, True)
                time.sleep(stepdelay)
                GPIO.output(self.step_pin, False)
                time.sleep(stepdelay)
                steps_taken += 1
                if verbose:
                    print("Step count {}".format(steps_taken), end="\r", flush=True)

        except KeyboardInterrupt:
            result = STOPPED
            print("User Keyboard Interrupt : RpiMotorLib:")
        except StopMotorInterrupt:
            result = STOPPED
            print("Stop Motor Interrupt : RpiMotorLib: ")
        except Exception as motor_error:
            result = ERROR
            print(sys.exc_info()[0])
            print(motor_error)
            print("RpiMotorLib  : Unexpected error:")
        else:
            # print report status
            if verbose:
                print("\nRpiMotorLib, Motor Run finished, Details:.\n")
                print("Result = {}".format(result))
                print("Motor type = {}".format(self.motor_type))
                print("Clockwise = {}".format(clockwise))
                print("Step Type = {}".format(steptype))
                print("Number of steps = {} of {}".format(steps_taken, steps))
                print("Step Delay = {}".format(stepdelay))
                print("Intial delay = {}".format(initdelay))
                print("Size of turn in degrees = {}"
                      .format(degree_calc(steps_taken, steptype)))
        finally:
            # cleanup
            GPIO.output(self.step_pin, False)
            GPIO.output(self.direction_pin, False)
            if self.mode_pins != False:
                for pin in self.mode_pins:
                    GPIO.output(pin, False)
        return result, steps_taken
                    
def degree_calc(steps, steptype):
    """ calculate and returns size of turn in degree
    , passed number of steps and steptype"""
    degree_value = {'Full': 1.8,
                    'Half': 0.9,
                    '1/4': .45,
                    '1/8': .225,
                    '1/16': 0.1125,
                    '1/32': 0.05625,
                    '1/64': 0.028125,
                    '1/128': 0.0140625}
    degree_value = (steps*degree_value[steptype])
    return degree_value
