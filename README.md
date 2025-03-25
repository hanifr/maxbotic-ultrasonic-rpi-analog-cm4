# maxbotic-ultrasonic-rpi-analog-cm4
 
Maxbotic Ultrasonic using Analog on RPI

Directory: /sys/bus/iio/devices/iio:device0

Command: cat in_voltage1_raw

Service required
1- fetch using cat
2-  process using multiplier constant (5 * in_voltage1_raw/1024)
3- watch on on RPI for continuous monitoring and data fetch
4- data upload to cloud using MQTT