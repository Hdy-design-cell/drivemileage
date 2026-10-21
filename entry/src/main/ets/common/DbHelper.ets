import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

// 行程记录数据结构
export interface DriveRecord {
  id?: number;
  startTime: number; // 开始时间戳
  endTime: number;   // 结束时间戳
  distance: number;  // 总里程，单位公里
  date: string;      // 日期 yyyy-MM-dd
  name?: string;     // 行程名称（可自定义）
  drivingDuration?: number; // 实际行驶时长（扣除暂停），毫秒
  segments?: string; // 分段时间JSON，格式 [[段开始,段结束],...]，毫秒时间戳
  segDistances?: string; // 分段里程JSON，格式 [0.05, 0.08,...]，公里
}

export class DbHelper {
  private static rdbStore: relationalStore.RdbStore | null = null;
  private static readonly TABLE_NAME: string = 'drive_record';

  // 初始化数据库
  static init(context: common.Context): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const config: relationalStore.StoreConfig = {
        name: 'drive_mileage.db',
        securityLevel: relationalStore.SecurityLevel.S1
      };
      relationalStore.getRdbStore(context, config, (err: BusinessError, store: relationalStore.RdbStore) => {
        if (err) {
          reject(err);
          return;
        }
        DbHelper.rdbStore = store;
        // 创建行程表（新装用户直接带 name、drivingDuration、segments 列）
        const createSql: string = `CREATE TABLE IF NOT EXISTS ${DbHelper.TABLE_NAME} (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          startTime INTEGER,
          endTime INTEGER,
          distance REAL,
          date TEXT,
          name TEXT,
          drivingDuration INTEGER,
          segments TEXT,
          segDistances TEXT
        )`;
        store.executeSql(createSql, (execErr: BusinessError) => {
          if (execErr) {
            reject(execErr);
            return;
          }
          // 老版本升级：给已存在的表补 name 列（重复执行报错，忽略即可）
          const alterSql: string = `ALTER TABLE ${DbHelper.TABLE_NAME} ADD COLUMN name TEXT`;
          store.executeSql(alterSql, () => {
            // 列已存在或加列成功，都算通过
          });
          // 老版本升级：补 drivingDuration 列
          const alterDrivingSql: string = `ALTER TABLE ${DbHelper.TABLE_NAME} ADD COLUMN drivingDuration INTEGER`;
          store.executeSql(alterDrivingSql, () => {
            // 列已存在或加列成功，都算通过
          });
          // 老版本升级：补 segments 列
          const alterSegmentsSql: string = `ALTER TABLE ${DbHelper.TABLE_NAME} ADD COLUMN segments TEXT`;
          store.executeSql(alterSegmentsSql, () => {
            // 列已存在或加列成功，都算通过
          });
          // 老版本升级：补 segDistances 列
          const alterSegDistSql: string = `ALTER TABLE ${DbHelper.TABLE_NAME} ADD COLUMN segDistances TEXT`;
          store.executeSql(alterSegDistSql, () => {
            // 列已存在或加列成功，都算通过
          });
          resolve();
        });
      });
    });
  }

  // 新增一条行程记录
  static addRecord(record: DriveRecord): Promise<number> {
    return new Promise<number>((resolve, reject) => {
      if (DbHelper.rdbStore === null) {
        reject(new Error('数据库未初始化'));
        return;
      }
      const value: relationalStore.ValuesBucket = {
        'startTime': record.startTime,
        'endTime': record.endTime,
        'distance': record.distance,
        'date': record.date,
        'name': record.name ?? '',
        'drivingDuration': record.drivingDuration ?? 0,
        'segments': record.segments ?? '',
        'segDistances': record.segDistances ?? ''
      };
      DbHelper.rdbStore.insert(DbHelper.TABLE_NAME, value, (err: BusinessError, rowId: number) => {
        if (err) {
          reject(err);
        } else {
          resolve(rowId);
        }
      });
    });
  }

  // 查询指定时间段的总里程
  static getTotalDistance(startTime: number, endTime: number): Promise<number> {
    return new Promise<number>((resolve, reject) => {
      if (DbHelper.rdbStore === null) {
        reject(new Error('数据库未初始化'));
        return;
      }
      const sql: string = `SELECT SUM(distance) as total FROM ${DbHelper.TABLE_NAME} WHERE startTime >= ? AND endTime <= ?`;
      DbHelper.rdbStore.querySql(sql, [startTime, endTime], (err: BusinessError, result: relationalStore.ResultSet) => {
        if (err) {
          reject(err);
          return;
        }
        let total: number = 0;
        if (result.goToFirstRow()) {
          total = result.getDouble(result.getColumnIndex('total')) || 0;
        }
        result.close();
        resolve(Math.round(total * 100) / 100);
      });
    });
  }

  // 查询所有历史行程，按时间倒序
  static getAllRecords(): Promise<DriveRecord[]> {
    return new Promise<DriveRecord[]>((resolve, reject) => {
      if (DbHelper.rdbStore === null) {
        reject(new Error('数据库未初始化'));
        return;
      }
      const sql: string = `SELECT * FROM ${DbHelper.TABLE_NAME} ORDER BY startTime DESC`;
      DbHelper.rdbStore.querySql(sql, [], (err: BusinessError, result: relationalStore.ResultSet) => {
        if (err) {
          reject(err);
          return;
        }
        const records: DriveRecord[] = [];
        while (result.goToNextRow()) {
          const nameIndex: number = result.getColumnIndex('name');
          const drivingIndex: number = result.getColumnIndex('drivingDuration');
          const segmentsIndex: number = result.getColumnIndex('segments');
          const segDistIndex: number = result.getColumnIndex('segDistances');
          records.push({
            id: result.getLong(result.getColumnIndex('id')),
            startTime: result.getLong(result.getColumnIndex('startTime')),
            endTime: result.getLong(result.getColumnIndex('endTime')),
            distance: result.getDouble(result.getColumnIndex('distance')),
            date: result.getString(result.getColumnIndex('date')),
            name: result.getString(nameIndex) || undefined,
            drivingDuration: drivingIndex >= 0 ? result.getLong(drivingIndex) : 0,
            segments: segmentsIndex >= 0 ? result.getString(segmentsIndex) || '' : '',
            segDistances: segDistIndex >= 0 ? result.getString(segDistIndex) || '' : ''
          });
        }
        result.close();
        resolve(records);
      });
    });
  }

  // 重命名行程
  static updateRecordName(id: number, name: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (DbHelper.rdbStore === null) {
        reject(new Error('数据库未初始化'));
        return;
      }
      const sql: string = `UPDATE ${DbHelper.TABLE_NAME} SET name = ? WHERE id = ?`;
      DbHelper.rdbStore.executeSql(sql, [name, id], (err: BusinessError) => {
        if (err) {
          reject(err);
        } else {
          resolve();
        }
      });
    });
  }

  // 删除行程
  static deleteRecord(id: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (DbHelper.rdbStore === null) {
        reject(new Error('数据库未初始化'));
        return;
      }
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(DbHelper.TABLE_NAME);
      predicates.equalTo('id', id);
      DbHelper.rdbStore.delete(predicates, (err: BusinessError) => {
        if (err) {
          reject(err);
        } else {
          resolve();
        }
      });
    });
  }
}
