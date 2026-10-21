// 距离计算工具类 - Haversine公式计算两点经纬度距离（单位：公里）
export class DistanceUtil {
  // 地球平均半径，单位：公里
  private static readonly EARTH_RADIUS: number = 6371.0;

  // 角度转弧度
  private static rad(d: number): number {
    return d * Math.PI / 180.0;
  }

  /**
   * 计算两点之间的实际距离
   * @param lat1 点1纬度
   * @param lng1 点1经度
   * @param lat2 点2纬度
   * @param lng2 点2经度
   * @returns 距离，单位：公里（km），不做四舍五入，保留完整精度
   */
  static calculateDistance(lat1: number, lng1: number, lat2: number, lng2: number): number {
    const radLat1: number = DistanceUtil.rad(lat1);
    const radLat2: number = DistanceUtil.rad(lat2);
    const a: number = radLat1 - radLat2;
    const b: number = DistanceUtil.rad(lng1) - DistanceUtil.rad(lng2);
    let s: number = 2 * Math.asin(Math.sqrt(Math.pow(Math.sin(a / 2), 2) +
      Math.cos(radLat1) * Math.cos(radLat2) * Math.pow(Math.sin(b / 2), 2)));
    s = s * DistanceUtil.EARTH_RADIUS;
    return s;
  }
}
