#define ISP_CHIP_ID_REG 0x0000

#define PAR_ISP_CHIP_ID 0x64
#define PAR_ISP_FRM_CNT 0x8006
#define PAR_ISP_RST_REG 0x001A
#define PAR_ISP_STANDBY_REG 0xDC02

#define MIPI_ISP_CHIP_ID 0x0265
#define MIPI_ISP_FRM_CNT 0x0002
#define MIPI_SENSOR_CHIP_ID_REG 0x3000
#define MIPI_ISP_STANDBY_REG 0xFFFE

#define AR0230_CHIP_ID 0x1056
#define AR0230_FRM_CNT_REG 0x303A
#define AR0230_STANDBY_REG 0X303C

#define AR0233_FRM_CNT_REG 0x2002
#define AR0233_CHIP_ID 0x0956
#define AR0233_STANDBY_REG 0X340E

#define AR0234_CHIP_ID 0X0A56
#define AR0234_STANDBY_REG 0X303C
#define AR0234_FRM_CNT_REG 0x303A

#define AR0821_CHIP_ID 0X2557
#define AR0821_STANDBY_REG 0X340E
#define AR0821_FRM_CNT_REG 0x2002

#define TWO_BYTE 2

struct econ_cam 
{
	uint8_t des_slave_addr;
	uint8_t ser_slave_addr;
	uint8_t mcu_slave_addr;
	uint8_t isp_slave_addr;
	uint8_t sensor_slave_addr;
	uint8_t gmsl_link_status;
        uint8_t ser_pclkdet;
	uint8_t is_i2c_trans;	
};
struct econ_stream_monitor
{
	struct i2c_client *client;
	struct cam *cam;
	struct econ_cam *ecam_state;
	
};

typedef struct sensor_reg {
	u16 reg;
	u16 val;
} SENSOR_REG;

SENSOR_REG par_sens_frm_cnt[] = {
	{0x0040, 0x8D00},
	{0xFC00, 0X0000},
	{0XFC02, 0X0200},
	{0X0040, 0X8D05},
	{0XFFFF, 0X0000},
	{0X0040, 0X8D08},
	{0XFFFF, 0X0000},
	{0X098E, 0X7C00},
};
SENSOR_REG par_sens_chip_id[] = {
	{0x0040, 0x8D00},
	{0xFC00, 0X3000},
	{0XFC02, 0X0200},
	{0X0040, 0X8D05},
	{0XFFFF, 0X0000},
	{0X0040, 0X8D08},
	{0XFFFF, 0X0000},
	{0X098E, 0X7C00},
};
SENSOR_REG par_sens_mode[] = {
	{0x0040, 0x8D00},
	{0xFC00, 0X0000},
	{0XFC02, 0X0200},
	{0X0040, 0X8D05},
	{0XFFFF, 0X0000},
	{0X0040, 0X8D08},
	{0XFFFF, 0X0000},
	{0X098E, 0X7C00},
};
char *sensor_model[] = {
	"ar0230",
	"ar0233",
	"ar0234",
	"ar0821",
};
enum econ_sensors{
	AR0230,
	AR0233,
	AR0234,
	AR0821,
};
enum sen_type{
	PAR_SENS,
	MIPI_SENS,
};
enum chip_type{
	ISP,
	SENSOR,
};
enum find_cam{
	CAM30_43 = 0,
	CAM30_44 = 1,
	CAM31_43 = 2,
	CAM31_44 = 3,
	CAM32_43 = 4,
	CAM32_44 = 5,
};

uint8_t sensor_name_index = 0xFF; 
const char *sensor_name = NULL;
const char *mcu_fw_name = NULL;
const char *dev_name_comp[6] = {NULL};
extern int frame_index_assign;

int serdes_err_handle(struct econ_stream_monitor *err_cam);
int serdes_link_status(struct econ_stream_monitor *err_cam);
int des_gmsl_link_lock_status(struct econ_stream_monitor *err_cam,	uint8_t err_handle);
int ser_video_status(struct econ_stream_monitor *err_cam,uint8_t err_handle);
int ser1_detect(struct econ_stream_monitor *err_cam,uint8_t err_handle);
int ser2_detect(struct econ_stream_monitor *err_cam,uint8_t err_handle);
int check_ser2_for_ser1_error(struct econ_stream_monitor *err_cam);
int check_ser1_for_ser2_error(struct econ_stream_monitor *err_cam);
int ser2_i2c_reassignment(struct econ_stream_monitor *err_cam);

int check_ser_i2c_translation(struct econ_stream_monitor *err_cam);
int i2c_trans_reg_read( struct econ_stream_monitor *err_cam,uint16_t reg_addr);
int re_write_i2c_trans_settings(struct econ_stream_monitor *err_cam,
		SERDES_PARSE *ser_conf,u32 reg_cnt);
int mcu_err_handle(struct econ_stream_monitor *err_cam,	uint8_t err_handle, uint8_t redo_isp_init);
int isp_sensor_err_handle(struct econ_stream_monitor *err_cam,	uint8_t err_handle);
int sensor_isp_write(struct i2c_client *err_client,uint16_t reg_addr, uint16_t reg_val);
int sensor_isp_read(struct i2c_client *err_client, uint16_t reg_addr, uint8_t reg_len);
int sensor_frame_count_read (struct i2c_client *err_client);
int sensor_chip_id_read (struct i2c_client *err_client);
uint8_t check_serializer_power_disconnect(struct econ_stream_monitor *err_cam);
int find_err_cam(char *err_cam_name);
int check_the_cam_status(struct cam *priv);
static int mcu_mipi_configuration(struct i2c_client *client, struct cam *priv, u8 cmd_id);


