import RPi.GPIO as GPIO
import time

pwm = 18

GPIO.setmode(GPIO.BCM)

#GPIO setup
GPIO.setup(pwm, GPIO.OUT) #Step

#PWM instance and frequency
pwm12 = GPIO.PWM(pwm, 0.5)

#start pwm with X% duty cycle
pwm12.start(10)